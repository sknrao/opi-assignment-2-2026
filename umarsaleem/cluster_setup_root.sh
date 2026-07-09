#!/usr/bin/env bash
# cluster_setup_root.sh — Phase 1: install k3s, create the OVS bridge, deploy
# CNAO and KubeVirt, copy a usable kubeconfig to the unprivileged user.
#
# Run once with sudo. After this completes, run cluster_setup_user.sh as your
# normal user to verify and print next steps.
#
# Idempotent: re-running is safe.

set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned versions (verified at plan time)
# ---------------------------------------------------------------------------
K3S_VERSION="${K3S_VERSION:-v1.35.6+k3s1}"          # KubeVirt v1.8.x supports k8s 1.34/1.35
CNAO_VERSION="${CNAO_VERSION:-v0.102.0}"
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.8.4}"

# Cluster sizing (mostly irrelevant for single-node but kept for consistency)
K3S_NODE_NAME="${K3S_NODE_NAME:-$(hostname)}"

# Lab network — host side of the OVS bridge
OVS_BRIDGE="${OVS_BRIDGE:-br-ovs}"
OVS_BRIDGE_IP="${OVS_BRIDGE_IP:-192.168.200.1/30}"
VM_IP="${VM_IP:-192.168.200.2/30}"

REAL_USER="${SUDO_USER:-}"

# Always talk to k3s via its explicit kubeconfig. When the script runs under
# sudo, the root user's environment may have a stale KUBECONFIG or a missing
# ~/.kube/config that points to localhost:8080 — kubectl then fails the
# OpenAPI validation step. Pinning the kubeconfig here avoids that.
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight (cheap, fail fast)
# ---------------------------------------------------------------------------
preflight() {
  [[ $EUID -eq 0 ]] || die "please run with sudo"
  [[ -e /dev/kvm ]] || die "/dev/kvm missing; KubeVirt needs nested virt"

  local f="/sys/module/kvm_intel/parameters/nested"
  [[ -e "$f" ]] || f="/sys/module/kvm_amd/parameters/nested"
  if [[ -e "$f" ]] && [[ "$(cat "$f")" != "Y" ]]; then
    warn "nested virt not enabled ($f != Y). Run: echo 1 | sudo tee $f"
    warn "Continuing in 5s; press Ctrl-C to abort..." >&2
    sleep 5
  else
    log "nested virt: enabled ✓"
  fi

  systemctl is-active --quiet libvirtd       || warn "libvirtd not active (KubeVirt will still work but libvirt diagnostics won't)"
  systemctl is-active --quiet openvswitch-switch || die "openvswitch-switch not active"
  log "host services up ✓"
}

# ---------------------------------------------------------------------------
# Install k3s
# ---------------------------------------------------------------------------
install_k3s() {
  if systemctl is-active --quiet k3s; then
    log "k3s already running"
    return
  fi

  log "installing k3s $K3S_VERSION (server, no traefik, no servicelb)"
  curl -sfL https://get.k3s.io \
    | INSTALL_K3S_VERSION="$K3S_VERSION" \
      INSTALL_K3S_EXEC="server --disable=traefik --disable=servicelb --node-name=$K3S_NODE_NAME" \
      sh -

  log "waiting for k3s.service to be active"
  for _ in $(seq 1 60); do
    systemctl is-active --quiet k3s && return
    sleep 2
  done
  die "k3s.service did not become active in 2 min; journalctl -u k3s"
}

# ---------------------------------------------------------------------------
# Hand kubeconfig to the unprivileged user
# ---------------------------------------------------------------------------
hand_off_kubeconfig() {
  [[ -n "$REAL_USER" && "$REAL_USER" != "root" ]] || {
    warn "SUDO_USER unset; kubeconfig not copied. To use kubectl as your user, do:\n  sudo cp /etc/rancher/k3s/k3s.yaml /home/<you>/.kube/config && sudo chown <you>:<you> /home/<you>/.kube/config"
    return
  }
  mkdir -p "/home/$REAL_USER/.kube"
  install -o "$REAL_USER" -g "$REAL_USER" -m 0600 \
    /etc/rancher/k3s/k3s.yaml "/home/$REAL_USER/.kube/config"
  log "kubeconfig installed at /home/$REAL_USER/.kube/config (chowned to $REAL_USER)"
}

# ---------------------------------------------------------------------------
# Create the host OVS bridge
# ---------------------------------------------------------------------------
create_ovs_bridge() {
  log "ensuring $OVS_BRIDGE exists with IP $OVS_BRIDGE_IP"
  ovs-vsctl --may-exist add-br "$OVS_BRIDGE"
  # Idempotent: ignore "RTNETLINK answers: File exists" on re-run.
  ip addr add "$OVS_BRIDGE_IP" dev "$OVS_BRIDGE" 2>/dev/null || true
  ip link set "$OVS_BRIDGE" up
  log "bridge state: $(ip -4 -o addr show dev "$OVS_BRIDGE" | awk '{print $4}')"
}

# ---------------------------------------------------------------------------
# Stage k3s's CNI plugin binaries under /opt/cni/bin
#
# k3s's kubelet invokes CNI plugins from /opt/cni/bin (CNI_PATH default).
# We need:
#   - the multicall `cni` binary (k3s bundles this; the k3s data dir
#     contains a `cni` executable plus symlinks named after each plugin
#     (flannel, bridge, bandwidth, ...). The symlinks use argv[0] dispatch.
#   - `multus-shim`, `ovs`, `macvtap`, `passthru` are already present
#     on this host (from OVS / everpeace / macvtap-cni installs) so we
#     do not touch them.
#
# We copy the k3s `cni` binary into /opt/cni/bin/ and create the
# relative symlinks for the multicall plugins. This lets the OVS-CNI
# plugin (running inside the multus-daemon pod) successfully exec
# flannel for the cluster-default network. Without this, multus-shim
# cannot find flannel and the OVS-CNI chain breaks.
# ---------------------------------------------------------------------------
install_k3s_cni_binaries() {
  local k3s_cni_src="/var/lib/rancher/k3s/data/cni/cni"
  local cni_dst="/opt/cni/bin/cni"

  if [[ ! -e "$k3s_cni_src" ]]; then
    die "k3s CNI multicall binary not found at $k3s_cni_src. Is k3s installed correctly?"
  fi

  log "staging k3s CNI multicall binary at $cni_dst (with relative symlinks)"
  # -L follows symlinks so the actual binary gets copied (not the symlink).
  cp -L "$k3s_cni_src" "$cni_dst"
  chmod 0755 "$cni_dst"

  for plugin in flannel bandwidth portmap host-local loopback bridge; do
    ln -sf cni "/opt/cni/bin/$plugin"
  done

  log "CNI plugin layout in /opt/cni/bin:"
  ls -la /opt/cni/bin/cni /opt/cni/bin/{flannel,bandwidth,portmap,host-local,loopback,bridge} | sed 's/^/    /'
}

# ---------------------------------------------------------------------------
# Install CNAO + apply NetworkAddonsConfig/cluster
# ---------------------------------------------------------------------------
install_cnao() {
  if kubectl get crd networkaddonsconfigs.networkaddonsoperator.network.kubevirt.io >/dev/null 2>&1; then
    log "CNAO CRD already present"
  else
    log "applying CNAO $CNAO_VERSION (namespace + CRD + operator)"
    kubectl apply -f "https://github.com/kubevirt/cluster-network-addons-operator/releases/download/${CNAO_VERSION}/namespace.yaml"
    kubectl apply -f "https://github.com/kubevirt/cluster-network-addons-operator/releases/download/${CNAO_VERSION}/network-addons-config.crd.yaml"
    kubectl apply -f "https://github.com/kubevirt/cluster-network-addons-operator/releases/download/${CNAO_VERSION}/operator.yaml"
    kubectl -n cluster-network-addons rollout status deploy/cluster-network-addons-operator --timeout=180s
  fi

  # Always apply the NAC spec we want. CNAO reconciles even on unchanged apply.
  # We deliberately do NOT include `multus: {}` here -- our custom multus
  # DaemonSet (see install_multus below) replaces CNAO's managed multus. We
  # also do NOT include `multusDynamicNetworks` -- that requires
  # multus != nil (CNAO validation) and MDNC's UpdateFunc-only design
  # makes it unsuitable for KubeVirt VMs that get the CNI annotation at
  # pod creation time. We don't need MDNC for our static binding config.
  log "applying NetworkAddonsConfig/cluster (ovs + kubeMacPool only; multus managed by install_multus)"
  cat <<EOF | kubectl apply -f -
apiVersion: networkaddonsoperator.network.kubevirt.io/v1
kind: NetworkAddonsConfig
metadata:
  name: cluster
spec:
  imagePullPolicy: IfNotPresent
  ovs: {}
  kubeMacPool: {}
EOF

  log "waiting for NetworkAddonsConfig/cluster to be Available (up to 5 min)"
  kubectl wait networkaddonsconfig cluster --for condition=Available --timeout=300s
  log "CNAO components:"
  kubectl -n cluster-network-addons get pods -o wide | sed 's/^/    /'
}

# ---------------------------------------------------------------------------
# Deploy our own Multus DaemonSet
#
# CNAO is configured with `multus: null`, so it does NOT deploy a Multus
# DaemonSet. We deploy our own with a critical mount that CNAO's template
# does not include: the host's /run/openvswitch directory. Without it,
# the OVS-CNI plugin (running inside the multus pod's container) cannot
# reach the OVS db.sock, so it cannot attach the veth to br-ovs. This is
# the single biggest correction vs. the working chain we discovered by
# running the lab: CNAO's multus template assumes a multus pod that does
# not need OVS, but our chain uses OVS as the secondary CNI.
# ---------------------------------------------------------------------------
install_multus() {
  local mp_ns="cluster-network-addons"
  local mp_name="multus"

  log "deploying custom Multus DaemonSet (with /run/openvswitch mount)"

  # ServiceAccount.
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${mp_name}
  namespace: ${mp_ns}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${mp_name}
rules:
  - apiGroups: ["k8s.cni.cncf.io"]
    resources: ["*"]
    verbs: ["*"]
  - apiGroups: [""]
    resources: ["pods", "pods/status"]
    verbs: ["get", "list", "update", "watch"]
  - apiGroups: [""]
    resources: ["events.k8s.io"]
    verbs: ["create", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${mp_name}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${mp_name}
subjects:
  - kind: ServiceAccount
    name: ${mp_name}
    namespace: ${mp_ns}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: multus-daemon-config
  namespace: ${mp_ns}
data:
  daemon-config.json: |
    {
        "chrootDir": "/hostroot",
        "cniVersion": "0.3.1",
        "logLevel": "verbose",
        "logToStderr": true,
        "cniConfigDir": "/host/etc/cni/net.d",
        "multusAutoconfigDir": "/host/etc/cni/net.d",
        "multusConfigFile": "auto",
        "socketDir": "/host/run/multus/"
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${mp_name}
  namespace: ${mp_ns}
  labels:
    tier: node
    app: multus
spec:
  selector:
    matchLabels:
      name: kube-multus-ds-amd64
  template:
    metadata:
      labels:
        tier: node
        app: multus
        name: kube-multus-ds-amd64
    spec:
      hostNetwork: true
      hostPID: true
      serviceAccountName: ${mp_name}
      containers:
        - name: kube-multus
          image: ghcr.io/k8snetworkplumbingwg/multus-cni@sha256:3c20900b5381fac7f9cbbdfac8370ea10a2f6ed7fbecc678384a9db57047abb1
          command: ["/usr/src/multus-cni/bin/multus-daemon"]
          resources:
            requests:
              cpu: "10m"
              memory: "15Mi"
          securityContext:
            privileged: true
          terminationMessagePolicy: FallbackToLogsOnError
          volumeMounts:
            - name: cni
              mountPath: /host/etc/cni/net.d
            - name: cnibin
              mountPath: /opt/cni/bin
            - name: host-run
              mountPath: /host/run
            - name: host-var-lib-cni-multus
              mountPath: /var/lib/cni/multus
            - name: host-var-lib-kubelet
              mountPath: /var/lib/kubelet
              mountPropagation: HostToContainer
            - name: host-run-k8s-cni-cncf-io
              mountPath: /run/k8s.cni.cncf.io
            - name: host-run-netns
              mountPath: /run/netns
              mountPropagation: HostToContainer
            - name: multus-daemon-config
              mountPath: /etc/cni/net.d/multus.d
              readOnly: true
            - name: hostroot
              mountPath: /hostroot
              mountPropagation: HostToContainer
            - mountPath: /etc/cni/multus/net.d
              name: multus-conf-dir
            # The fix: mount host's OVS db.sock directory so the OVS-CNI
            # plugin (running in this pod) can talk to the OVS database.
            - name: host-ovs-sock
              mountPath: /var/run/openvswitch
          env:
            - name: MULTUS_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          imagePullPolicy: IfNotPresent
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "rm -rf /host/etc/cni/net.d/00-multus.conf /host/var/lib/cni/*"]
      initContainers:
        - name: install-multus-binary
          image: ghcr.io/k8snetworkplumbingwg/multus-cni@sha256:3c20900b5381fac7f9cbbdfac8370ea10a2f6ed7fbecc678384a9db57047abb1
          command:
            - "/usr/src/multus-cni/bin/install_multus"
            - "-d"
            - "/host/opt/cni/bin"
            - "-t"
            - "thick"
          resources:
            requests:
              cpu: "10m"
              memory: "15Mi"
          securityContext:
            privileged: true
          terminationMessagePolicy: FallbackToLogsOnError
          volumeMounts:
            - name: cnibin
              mountPath: /host/opt/cni/bin
              mountPropagation: Bidirectional
      volumes:
        - name: cni
          hostPath:
            path: /etc/cni/net.d
        - name: cnibin
          hostPath:
            path: /opt/cni/bin
        - name: hostroot
          hostPath:
            path: /
        - name: multus-daemon-config
          configMap:
            name: multus-daemon-config
            items:
              - key: daemon-config.json
                path: daemon-config.json
        - name: host-run
          hostPath:
            path: /run
        - name: host-var-lib-cni-multus
          hostPath:
            path: /var/lib/cni/multus
        - name: host-var-lib-kubelet
          hostPath:
            path: /var/lib/kubelet
        - name: host-run-k8s-cni-cncf-io
          hostPath:
            path: /run/k8s.cni.cncf.io
        - name: host-run-netns
          hostPath:
            path: /run/netns/
        - name: multus-conf-dir
          hostPath:
            path: /etc/cni/multus/net.d
        - name: host-ovs-sock
          hostPath:
            path: /run/openvswitch
      tolerations:
        - key: CriticalAddonsOnly
          operator: Exists
EOF

  log "waiting for Multus DaemonSet to be ready (up to 2 min)"
  kubectl -n ${mp_ns} rollout status ds ${mp_name} --timeout=120s
  kubectl -n ${mp_ns} wait pod -l app=multus --for=condition=ready --timeout=120s
}

# ---------------------------------------------------------------------------
# Stage 00-multus.conf into k3s's CNI config directory
#
# k3s's kubelet reads CNI configs from
# /var/lib/rancher/k3s/agent/etc/cni/net.d/ -- NOT /etc/cni/net.d/ as
# upstream kubernetes does. Our Multus DaemonSet writes its 00-multus.conf
# to /etc/cni/net.d/ (which is what /host/etc/cni/net.d/ resolves to
# inside the multus pod), so we copy that conf into k3s's actual
# read directory. Idempotent: re-runs overwrite the same file.
# ---------------------------------------------------------------------------
install_k3s_cni_config() {
  local k3s_cni_dir="/var/lib/rancher/k3s/agent/etc/cni/net.d"
  local source="/etc/cni/net.d/00-multus.conf"
  local target="${k3s_cni_dir}/00-multus.conf"
  local end=$((SECONDS + 60))

  # The multus pod's preStart creates 00-multus.conf on /etc/cni/net.d/,
  # but if install_multus() returned early (e.g. due to a transient
  # containerd pull delay), the conf may not exist yet. Wait briefly
  # before giving up.
  log "waiting for 00-multus.conf to appear at $source"
  while [[ ! -f "$source" ]]; do
    if [[ $SECONDS -ge $end ]]; then
      die "00-multus.conf not found at $source within 60s -- multus pod may have failed to start. Check: kubectl -n cluster-network-addons logs -l app=multus"
    fi
    sleep 2
  done

  log "staging 00-multus.conf into k3s's CNI config directory ($k3s_cni_dir)"
  mkdir -p "$k3s_cni_dir"
  cp "$source" "$target"
  chmod 0600 "$target"
  log "00-multus.conf content:"
  cat "$target" | sed 's/^/    /'
}

# ---------------------------------------------------------------------------
# Install KubeVirt operator + CR
# ---------------------------------------------------------------------------
install_kubevirt() {
  if ! kubectl get crd kubevirts.kubevirt.io >/dev/null 2>&1; then
    log "applying KubeVirt $KUBEVIRT_VERSION operator"
    kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
  fi

  if ! kubectl get kubevirt -n kubevirt kubevirt >/dev/null 2>&1; then
    log "applying KubeVirt CR"
    kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"
  fi

  log "waiting for KubeVirt to reach Deployed (up to 10 min)"
  # Don't fail the script on timeout — at this point KubeVirt usually *is*
  # Deployed and the wait just hit the race window between polling. We re-
  # check after the timeout and continue if Deployed.
  if ! kubectl -n kubevirt wait kubevirt kubevirt \
       --for=jsonpath='{.status.phase}'=Deployed --timeout=600s; then
    phase=$(kubectl -n kubevirt get kubevirt kubevirt -o jsonpath='{.status.phase}' 2>/dev/null || echo unknown)
    if [[ "$phase" == "Deployed" ]]; then
      log "wait timed out but KubeVirt is Deployed; continuing"
    else
      die "KubeVirt not Deployed after wait (current phase: $phase). journalctl -u k3s + kubectl get kubevirt -n kubevirt kubevirt -o yaml"
    fi
  fi

  # Patch the KubeVirt CR with our runtime config:
  #   - useEmulation: true — the KVM device plugin path has a separate
  #     libvirt/permission issue (see below). Falling back to TCG
  #     software emulation gives us a working VM with the OVS-CNI
  #     secondary network, which is what the lab needs. Hardware KVM
  #     acceleration is left for a follow-up investigation.
  #   - ovsTap binding: KubeVirt's `tap` domain attachment type fails
  #     on our chain because OVS-CNI creates a veth in the pod, not a
  #     tap device, and libvirt can't open a veth as a tap. The
  #     `managedTap` domain attachment type creates its own tap and
  #     bridges it to the veth, sidestepping the issue.
  log "patching KubeVirt CR with useEmulation and ovsTap.managedTap"
  kubectl patch kubevirt -n kubevirt kubevirt --type=merge -p='{
    "spec": {
      "configuration": {
        "developerConfiguration": {"useEmulation": true},
        "network": {
          "binding": {
            "ovsTap": {"domainAttachmentType": "managedTap"}
          }
        }
      }
    }
  }'
  log "KubeVirt CR config:"
  kubectl -n kubevirt get kubevirt kubevirt -o jsonpath='{.spec.configuration}' | sed 's/^/    /'

  # KVM hardware acceleration is not currently usable on this lab.
  # Investigation found that:
  #   - The host's /dev/kvm is mode 0660 root:kvm, and the kernel
  #     modules (kvm_intel, kvm) are loaded with nested virt enabled.
  #   - The everpeace/k8s-host-device-plugin advertises
  #     devices.kubevirt.io/kvm on the node. The KubeVirt operator
  #     generates launcher pods that request this resource when
  #     useEmulation is unset.
  #   - With useEmulation: unset, the launcher pod requests
  #     devices.kubevirt.io/kvm: 1 and KubeVirt's own kubevirt-kvm
  #     device plugin bind-mounts /dev/kvm into the pod (the in-pod
  #     /dev/kvm shows owner qemu:qemu, mode 0660, matching the
  #     launcher's runAsUser 107).
  #   - However, libvirt inside the pod still fails with
  #     `Unable to open /dev/kvm: Permission denied` at
  #     virHostCPUGetCPUID. Direct `</dev/kvm` from bash works, so
  #     this is likely a cgroup v2 device filter issue or a libvirt
  #     bug with the bundled KVM. The fallback to TCG via useEmulation
  #     is the working path.
  # To enable KVM hardware acceleration, the next investigation
  # steps are:
  #   1. Verify cgroup v2 device.allow for the launcher's cgroup
  #      (e.g. /sys/fs/cgroup/kubepods.slice/.../cgroup.subtree_control,
  #      or check eBPF device filter status).
  #   2. If the device is blocked by cgroup, add a `devices.allow` rule
  #      via a privileged init container.
  #   3. If the device is unblocked but libvirt still fails, consider
  #      upgrading the in-pod libvirt to a version that supports
  #      the kernel's KVM_GET_API_VERSION response.
}

# ---------------------------------------------------------------------------
# Install everpeace/k8s-host-device-plugin for /dev/kvm
#
# The kubevirt/kubernetes-device-plugins/kvm DaemonSet (which would have
# been the obvious choice) crashes on registration against modern kubelet
# due to a v1beta1 device plugin API issue (see ISSUES.md, category 1b).
# everpeace/k8s-host-device-plugin is a thin plugin that works with
# current kubelet and advertises /dev/kvm as kubevirt.io/kvm.
#
# Note: Docker Hub only exposes the rolling `latest` tag (no version-pinned
# tag is published for the 1.35.0-0.1.0 source release). Acceptable for a
# lab environment; not reproducible for production.
# ---------------------------------------------------------------------------
KVM_DEVICE_PLUGIN_IMAGE="everpeace/k8s-host-device-plugin:latest"
KVM_DEVICE_PLUGIN_CONFIG='{
  "resourceName": "devices.kubevirt.io/kvm",
  "socketName": "devices.kubevirt.io_kvm.sock",
  "numDevices": 100,
  "hostDevices": [{
    "hostPath": "/dev/kvm",
    "containerPath": "/dev/kvm",
    "permission": "rw"
  }]
}'

install_kvm_device_plugin() {
  # If the broken kubevirt one is still around, remove it so we don't
  # have two plugins advertising the same resource.
  if kubectl -n default get ds device-plugin-kvm >/dev/null 2>&1; then
    log "removing the broken kubevirt device-plugin-kvm DaemonSet"
    kubectl -n default delete ds device-plugin-kvm --ignore-not-found
    # Wait for its pod to actually be gone.
    kubectl -n default wait pod -l name=device-plugin-kvm \
      --for=delete --timeout=120s 2>/dev/null || true
  fi

  log "applying everpeace/k8s-host-device-plugin (advertises /dev/kvm as kubevirt.io/kvm)"

  if ! kubectl -n kube-system get cm kvm-host-devices >/dev/null 2>&1; then
    kubectl -n kube-system create configmap kvm-host-devices \
      --from-literal=config.json="$KVM_DEVICE_PLUGIN_CONFIG"
  else
    log "kvm-host-devices ConfigMap already present"
  fi

  if ! kubectl -n kube-system get ds kvm-host-device-plugin >/dev/null 2>&1; then
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kvm-host-device-plugin
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: kvm-host-device-plugin-ds
  template:
    metadata:
      annotations:
        scheduler.alpha.kubernetes.io/critical-pod: ""
      labels:
        name: kvm-host-device-plugin-ds
    spec:
      tolerations:
        - key: CriticalAddonsOnly
          operator: Exists
      containers:
        - name: kvm-host-device-plugin-ctr
          image: $KVM_DEVICE_PLUGIN_IMAGE
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 50m
              memory: 50Mi
          # The image's ENTRYPOINT reads CONFIG_DIR from env. Do NOT add
          # an args: field — that overrides the entrypoint and runc tries
          # to exec the arg as a literal path (see everpeace docs example).
          env:
            - name: CONFIG_DIR
              value: /k8s-host-device-plugin
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
            - name: dev-kvm
              mountPath: /dev/kvm
            - name: config
              mountPath: /k8s-host-device-plugin
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
        - name: dev-kvm
          hostPath:
            path: /dev/kvm
        - name: config
          configMap:
            name: kvm-host-devices
            items:
              - key: config.json
                path: config.json
EOF
  else
    log "kvm-host-device-plugin DaemonSet already present"
  fi

  # Wait for the plugin pod to register with the kubelet.
  log "waiting for /dev/kvm to be advertised as kubevirt.io/kvm"
  for _ in $(seq 1 30); do
    if kubectl describe node 2>/dev/null | grep -q "devices.kubevirt.io/kvm:"; then
      log "kubevirt.io/kvm resource visible to the cluster"
      return 0
    fi
    sleep 3
  done
  warn "kubevirt.io/kvm did not appear within 90s. Check: kubectl -n kube-system logs -l name=kvm-host-device-plugin-ds"
  return 0
}

# ---------------------------------------------------------------------------
# Readiness report
# ---------------------------------------------------------------------------
readiness_report() {
  echo
  log "===== READINESS ====="
  log "nodes:"
  kubectl get nodes -o wide | sed 's/^/    /'

  log "k3s pods (kube-system + CNAO + KubeVirt):"
  kubectl get pods -A | sed 's/^/    /'

  log "networkaddonsconfig:"
  kubectl get networkaddonsconfig | sed 's/^/    /'

  log "kubevirt:"
  kubectl get kubevirt -A | sed 's/^/    /'

  log "br-ovs:"
  ovs-vsctl show | sed 's/^/    /'

  local nf
  nf=$(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || echo unknown)
  log "bridge-nf-call-iptables: $nf"
  if [[ "$nf" != "1" ]]; then
    warn "expected 1; if VM connectivity breaks, fix with: echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables"
  fi

  echo
  cat <<EOF
============================================================
  Phase 1 (root) complete.
============================================================

  IMPORTANT: After every host reboot, the OVS bridge (\$OVS_BRIDGE)
  comes back in DOWN state with no IP. A companion systemd unit
  (cluster-setup-restore-bridge.service in this repo) re-applies
  the link state and IP automatically on boot. To install it once:
    sudo install -m 0755 cluster-setup-restore-bridge.sh /usr/local/bin/
    sudo install -m 0644 cluster-setup-restore-bridge.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable cluster-setup-restore-bridge.service
  Manual fallback if the unit is not installed:
    sudo ip link set \$OVS_BRIDGE up
    sudo ip addr add \$OVS_BRIDGE_IP dev \$OVS_BRIDGE

Next: Phase 2 (no privileges needed)
  ./cluster_setup.sh                # verifies the cluster from your user account

Then (still as $REAL_USER or whoever owns the kubeconfig):
  kubectl apply -f manifests.yaml
  virtctl -n vm-lab start cirros-vm
  kubectl -n vm-lab wait vmi cirros-vm --for condition=Ready --timeout=180s

  # Cloud-init runcmd in manifests.yaml does NOT auto-execute on this
  # CirrOS image (Linux 4.4.0-28, BusyBox 1.23.2). The VM will boot with
  # eth0 up but with no IPv4 address. You must set the IP from inside
  # the VM console:
  #
  #   virtctl -n vm-lab console cirros-vm
  #     login: cirros / gocubsgo
  #     sudo -i
  #     ip addr add 192.168.200.2/30 dev eth0
  #     ip route add default via 192.168.200.1 dev eth0
  #     exit (Ctrl-])
  #
  # After the IP is set, verify with:
  #   arping -c 3 -I br-ovs 192.168.200.2
  #   ping -c 4 192.168.200.2
  #   sudo ovs-ofctl dump-flows br-ovs
  #   sudo ovs-ofctl dump-ports br-ovs

To uninstall the lab so this script can be re-run from scratch:
  sudo $0 cleanup

EOF
}

# ---------------------------------------------------------------------------
# Cleanup (uninstall the lab so the script can be re-run from scratch)
#
# Idempotent: every step is guarded with `|| true` or `-ignore-not-found`
# so the cleanup can be run multiple times without error. Use this when
# you want to verify that a fresh install of cluster_setup_root.sh will
# produce the same end-state as the current install.
#
# This does NOT uninstall k3s itself; it removes the cluster-side
# artifacts that the script creates. Run `k3s-uninstall.sh` separately
# if you also want a clean k3s.
# ---------------------------------------------------------------------------
cleanup() {
  log "removing cluster-side artifacts created by this script"

  # Custom Multus DaemonSet.
  kubectl -n cluster-network-addons delete ds multus --ignore-not-found 2>/dev/null || true
  kubectl -n cluster-network-addons delete cm multus-daemon-config --ignore-not-found 2>/dev/null || true
  kubectl -n cluster-network-addons delete sa multus --ignore-not-found 2>/dev/null || true
  kubectl delete clusterrole multus --ignore-not-found 2>/dev/null || true
  kubectl delete clusterrolebinding multus --ignore-not-found 2>/dev/null || true

  # k3s CNI config we copied in.
  rm -f /var/lib/rancher/k3s/agent/etc/cni/net.d/00-multus.conf 2>/dev/null || true

  # Multus's own 00-multus.conf at /etc/cni/net.d/ (written by the
  # multus pod, removed by its preStop hook on shutdown -- but if the
  # pod is gone, clean up the file too).
  rm -f /etc/cni/net.d/00-multus.conf 2>/dev/null || true

  # k3s CNI binaries we copied/symlinked.
  rm -f /opt/cni/bin/cni 2>/dev/null || true
  for plugin in flannel bandwidth portmap host-local loopback bridge; do
    rm -f "/opt/cni/bin/$plugin" 2>/dev/null || true
  done

  # NOTE: /etc/cni/net.d/10-flannel.conflist is host-managed (created by
  # k3s's bundled flannel during initial install). It is NOT removed by
  # this cleanup; if you wipe /etc/cni/net.d/ entirely, k3s's
  # flannel-vxlan service will recreate it on next pod scheduling.
  # Likewise, /etc/cni/net.d/00-multus.conf is written by the multus
  # pod on startup; we leave the host directory cleanup to that pod's
  # preStop hook. Removing multus first (above) triggers that preStop,
  # which removes the conf. If the multus pod is already gone, the
  # host's 00-multus.conf file may linger; remove it manually.

  # KubeVirt CR patches are part of the CR object; deleting kubevirt
  # CR will reset them. We don't delete the CR here -- uninstall k3s
  # for that. We do, however, reset the KubeVirt CR config to defaults
  # so a subsequent install_kubevirt() applies them cleanly.
  log "resetting KubeVirt CR to stock config (drop useEmulation and ovsTap.managedTap)"
  kubectl patch kubevirt -n kubevirt kubevirt --type=merge -p='{
    "spec": {
      "configuration": null
    }
  }' 2>/dev/null || true

  # KVM device plugin (if installed).
  kubectl -n kube-system delete ds kvm-host-device-plugin --ignore-not-found 2>/dev/null || true
  kubectl -n kube-system delete cm kvm-host-devices --ignore-not-found 2>/dev/null || true

  # KubeVirt operator is left in place; uninstall via k3s-uninstall.sh.
  # CNAO is left in place; uninstall via k3s-uninstall.sh.

  # VM and namespace.
  kubectl delete vm cirros-vm -n vm-lab --force --grace-period=0 --ignore-not-found 2>/dev/null || true
  kubectl delete ns vm-lab --ignore-not-found 2>/dev/null || true

  log "cleanup done. Re-run with: sudo $0"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  preflight
  install_k3s
  hand_off_kubeconfig
  create_ovs_bridge
  install_k3s_cni_binaries
  install_cnao
  install_multus
  install_k3s_cni_config
  install_kubevirt
  install_kvm_device_plugin
  readiness_report
}

main "$@"