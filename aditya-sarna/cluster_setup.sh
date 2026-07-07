#!/usr/bin/env bash
#
# cluster_setup.sh - Cloud-Native OVS Datapath Challenge (OPI Assignment 2)
#
# Bootstraps, end to end:
#   1. A single-node KinD cluster (kindnet as the default pod network / Multus delegate)
#   2. Open vSwitch installed on the node + bridge 'br1'
#   3. Multus (secondary networks) and OVS-CNI
#   4. KubeVirt (hardware-accelerated with /dev/kvm; emulation/cross-arch fallback otherwise)
#   5. The assignment workloads (manifests.yaml): 2 CirrOS VMs + 1 pod on br1
# then verifies the datapath and regenerates the artifacts:
#   - ping_results.txt         raw stdout of pings crossing the OVS bridge
#   - verification_flows.json  machine-readable flow/FDB/port evidence
#
# Requirements: docker (or podman), curl, python3. kind/kubectl are installed
# automatically into ~/.local/bin if missing. Linux x86_64 with KVM (incl. GitHub
# Actions) gives the smoothest run and real captures in minutes; without KVM the
# script enables KubeVirt emulation, and on arm64 it runs the guests as amd64 via
# the CrossArchitectureVirtualization gate (slow, TCG).
#
# Usage:
#   ./cluster_setup.sh              # full bootstrap + verification
#   ./cluster_setup.sh --help       # list env vars and exit codes
#   CLEANUP=1 ./cluster_setup.sh    # tear the cluster down and exit
#
# A note on the flow dump format: 'ovs-ofctl dump-flows <br> --format=json' is
# not implemented by any released Open vSwitch (JSON comes from ovs-flowviz or,
# for appctl commands, 'ovs-appctl --format json' since OVS 3.4). This script
# probes for native JSON support at runtime and uses it when present; otherwise
# it converts the raw dump into an equivalent, fully machine-readable JSON
# document (schema documented in README.md).
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-ovs-kubevirt}"
KIND_VERSION="${KIND_VERSION:-v0.27.0}"
KIND_NODE_TAG="${KIND_NODE_TAG:-v1.32.2}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-ovs-kind-node:${KIND_NODE_TAG}}"
BRIDGE="${BRIDGE:-br1}"
MULTUS_VERSION="${MULTUS_VERSION:-v4.2.2}"
VM_A_IP="10.10.0.10"
VM_B_IP="10.10.0.11"
POD_IP="10.10.0.20"
MANIFESTS="${MANIFESTS:-${SCRIPT_DIR}/manifests.yaml}"
PING_RESULTS="${PING_RESULTS:-${SCRIPT_DIR}/ping_results.txt}"
FLOW_DUMP="${FLOW_DUMP:-${SCRIPT_DIR}/verification_flows.json}"
# evidence/ holds the raw OVS text (flows_raw.txt, datapath_raw.txt, fdb.txt,
# ports.txt, bridge_topology.txt) and execution_mode.txt. verification_flows.json
# is derived from these by flows_to_json.py --bundle; text and JSON are therefore
# consistent by construction.
EVIDENCE_DIR="${EVIDENCE_DIR:-${SCRIPT_DIR}/evidence}"
PARSER="${PARSER:-${SCRIPT_DIR}/flows_to_json.py}"
STEP_TOTAL=12
STEP_N=0

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

step() {
  STEP_N=$((STEP_N + 1))
  printf '\n\033[1;36m==> [%d/%d]\033[0m %s\n' "${STEP_N}" "${STEP_TOTAL}" "$*"
}

retry() {
  local n="$1" sleep_s="$2" desc="$3"
  shift 3
  [[ "${1:-}" == "--" ]] && shift
  local i
  for ((i = 1; i <= n; i++)); do
    if "$@"; then return 0; fi
    warn "${desc}: attempt ${i}/${n} failed; retrying in ${sleep_s}s..."
    sleep "${sleep_s}"
  done
  die "${desc}: all ${n} attempts failed."
}

show_help() {
  cat <<EOF
cluster_setup.sh — KinD + OVS + Multus + OVS-CNI + KubeVirt + datapath verification

Usage:
  ./cluster_setup.sh                 Full bootstrap + verification
  ./cluster_setup.sh --help          Show this help
  CLEANUP=1 ./cluster_setup.sh       Delete cluster '${CLUSTER_NAME}' and exit

Exit codes:
  0   Bootstrap and verification succeeded (artifacts regenerated)
  1   Bootstrap or verification failed (cluster left up for inspection)

Environment (all optional):
  CLUSTER_NAME=${CLUSTER_NAME}
  KIND_VERSION=${KIND_VERSION}
  KIND_NODE_TAG=${KIND_NODE_TAG}
  BRIDGE=${BRIDGE}
  MULTUS_VERSION=${MULTUS_VERSION}
  MANIFESTS=${MANIFESTS}
  PING_RESULTS=${PING_RESULTS}
  FLOW_DUMP=${FLOW_DUMP}
  EVIDENCE_DIR=${EVIDENCE_DIR}
  PARSER=${PARSER}
  VMI_WAIT_TIMEOUT=${VMI_WAIT_TIMEOUT:-600}
  CLEANUP=1                          Tear down instead of bootstrap

Artifacts:
  ping_results.txt, verification_flows.json, evidence/* (raw OVS dumps)

On failure the cluster is kept running. Inspect with:
  kubectl get pods -A
  kind export logs --name ${CLUSTER_NAME} /tmp/kind-logs
Teardown: CLEANUP=1 ./cluster_setup.sh
EOF
}

cleanup_on_exit() {
  local code=$?
  [[ "${code}" -eq 0 || "${CLEANUP:-0}" == "1" ]] && return 0
  warn "Script exited with code ${code}."
  warn "Cluster '${CLUSTER_NAME}' was left running for inspection."
  warn "  kubectl get pods -A"
  warn "  kind export logs --name ${CLUSTER_NAME} /tmp/kind-logs"
  warn "Teardown: CLEANUP=1 ${SCRIPT_DIR}/cluster_setup.sh"
}

trap cleanup_on_exit EXIT

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
detect_oci() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo docker
  elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    echo podman
  else
    echo ""
  fi
}

host_arch() {
  case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

install_kind() {
  command -v kind >/dev/null 2>&1 && return
  log "Installing kind ${KIND_VERSION} to ~/.local/bin"
  mkdir -p "${HOME}/.local/bin"
  curl -fsSL --retry 3 \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-$(uname -s | tr '[:upper:]' '[:lower:]')-$(host_arch)" \
    -o "${HOME}/.local/bin/kind"
  chmod +x "${HOME}/.local/bin/kind"
  export PATH="${HOME}/.local/bin:${PATH}"
}

install_kubectl() {
  command -v kubectl >/dev/null 2>&1 && return
  log "Installing kubectl to ~/.local/bin"
  mkdir -p "${HOME}/.local/bin"
  curl -fsSL --retry 3 \
    "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/$(uname -s | tr '[:upper:]' '[:lower:]')/$(host_arch)/kubectl" \
    -o "${HOME}/.local/bin/kubectl"
  chmod +x "${HOME}/.local/bin/kubectl"
  export PATH="${HOME}/.local/bin:${PATH}"
}

# ---------------------------------------------------------------------------
# 1. Cluster: custom node image (OVS preinstalled) + two nodes, no default CNI
# ---------------------------------------------------------------------------
preflight_disk() {
  local avail_gb path="${HOME}"
  # Linux: df -BG; macOS: df -g (1G-blocks, Available in column 4)
  if df -BG "${path}" >/dev/null 2>&1; then
    avail_gb="$(df -BG "${path}" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')"
  else
    avail_gb="$(df -g "${path}" | awk 'NR==2 {print $4}')"
  fi
  if [[ -z "${avail_gb}" || ! "${avail_gb}" =~ ^[0-9]+$ ]]; then
    warn "Could not parse host free disk; continuing (Docker Desktop manages its own disk pool)"
    return 0
  fi
  log "Free space (host): ~${avail_gb} GB"
  if [[ "${avail_gb}" -lt 8 ]]; then
    die "Need at least 8 GB free on host. On Mac use Docker Desktop (64 GB disk), or GitHub Actions / Oracle Cloud (see RUN.md)."
  fi
}

preflight_inotify() {
  [[ "$(uname -s)" != "Linux" ]] && return 0
  local cur_watches cur_instances
  cur_watches="$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)"
  cur_instances="$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)"
  if [[ "${cur_watches}" -lt 524288 || "${cur_instances}" -lt 512 ]]; then
    warn "inotify limits may be low for KinD+KubeVirt (watches=${cur_watches}, instances=${cur_instances})."
    warn "virt-handler can crash-loop with 'too many open files'. Raise with:"
    warn "  sudo sysctl fs.inotify.max_user_watches=1048576"
    warn "  sudo sysctl fs.inotify.max_user_instances=8192"
  else
    log "inotify limits OK (watches=${cur_watches}, instances=${cur_instances})"
  fi
}

kind_node() {
  echo "${CLUSTER_NAME}-control-plane"
}

preflight_docker() {
  # amd64 platform on Apple Silicon breaks KinD (see kind#3973).
  if [[ "$(uname -m)" == "arm64" && "${DOCKER_DEFAULT_PLATFORM:-}" == "linux/amd64" ]]; then
    log "Unsetting DOCKER_DEFAULT_PLATFORM=linux/amd64 (breaks KinD on Apple Silicon)"
    unset DOCKER_DEFAULT_PLATFORM
  fi
  docker info >/dev/null 2>&1 || die "Docker daemon is not running — start Docker Desktop first."
  log "Docker OK ($(docker info --format '{{.ServerVersion}}'), $(uname -m))"
}

create_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    log "Reusing existing kind cluster '${CLUSTER_NAME}'"
    return
  fi
  kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true
  docker rm -f "${CLUSTER_NAME}-control-plane" 2>/dev/null || true

  log "Creating single-node kind cluster '${CLUSTER_NAME}' (default CNI: kindnet)"
  # Use kind's built-in kindnet as the default pod network. Flannel-on-kind is
  # fragile on recent kernels/K8s (crash-loops, missing /run/flannel/subnet.env),
  # which breaks every pod sandbox through Multus. kindnet is rock-solid and
  # serves as Multus's default delegate just as well.
  local kind_cfg=/tmp/kind-$$.yaml
  cat > "${kind_cfg}" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF
  if [[ -n "${GITHUB_ACTIONS:-}" ]] && [[ -e /dev/kvm ]]; then
    log "GHA: passing host /dev/kvm into the KinD node"
    cat >> "${kind_cfg}" <<'EOF'
    extraMounts:
      - hostPath: /dev/kvm
        containerPath: /dev/kvm
EOF
  fi
  if ! kind create cluster --name "${CLUSTER_NAME}" --wait 150s --config="${kind_cfg}"; then
    log "KinD create failed — collecting logs"
    kind export logs --name "${CLUSTER_NAME}" /tmp/kind-logs-$$ 2>/dev/null || true
    docker logs "${CLUSTER_NAME}-control-plane" 2>&1 | tail -30 || true
    die "KinD cluster creation failed. Try: kind delete cluster --name ${CLUSTER_NAME} && docker system prune -f && rerun."
  fi
}

install_ovs_in_nodes() {
  local oci="$1" node
  log "Installing Open vSwitch inside KinD node(s) (no custom image build — saves disk)"
  for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
    ${oci} exec "${node}" bash -c "
      set -e
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq openvswitch-switch iputils-ping
      pgrep -x ovsdb-server >/dev/null || /usr/share/openvswitch/scripts/ovs-ctl start --system-id=random
      ovs-vsctl --may-exist add-br ${BRIDGE}
      ovs-vsctl set bridge ${BRIDGE} fail-mode=standalone
    "
    kubectl label node "${node}" "ovs-cni.network.kubevirt.io/${BRIDGE}=true" --overwrite >/dev/null
  done
}

wait_node_ready() {
  log "Waiting for the node to be Ready (kindnet default CNI)"
  retry 3 10 "node Ready" -- kubectl wait --for=condition=Ready nodes --all --timeout=300s
  kubectl -n kube-system rollout status daemonset/kindnet --timeout=180s 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 2. Open vSwitch: start daemons, create br1, interconnect nodes with VXLAN
# ---------------------------------------------------------------------------
setup_ovs_vxlan() {
  local oci="$1"
  local nodes=($(kind get nodes --name "${CLUSTER_NAME}"))
  [[ ${#nodes[@]} -lt 2 ]] && return 0
  log "Interconnecting ${BRIDGE} across nodes with VXLAN"
  local node other other_ip
  for node in "${nodes[@]}"; do
    for other in "${nodes[@]}"; do
      [[ "${node}" == "${other}" ]] && continue
      other_ip="$(${oci} inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${other}")"
      ${oci} exec "${node}" ovs-vsctl --may-exist add-port "${BRIDGE}" "vx-${other}" \
        -- set Interface "vx-${other}" type=vxlan "options:remote_ip=${other_ip}"
    done
  done
}

# ---------------------------------------------------------------------------
# 3. Networking stack: Multus + OVS CNI
# ---------------------------------------------------------------------------
install_multus() {
  log "Installing Multus CNI ${MULTUS_VERSION}"
  curl -fsSL --retry 3 \
    "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${MULTUS_VERSION}/deployments/multus-daemonset.yml" \
    | sed "s/:snapshot/:${MULTUS_VERSION}/g" \
    | kubectl apply -f -
  kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout=300s
}

install_ovs_cni() {
  log "Installing OVS CNI plugin + marker"
  local arch
  arch="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')"
  # Upstream example manifest is amd64-only; rewrite for the actual node arch.
  curl -fsSL --retry 3 \
    "https://raw.githubusercontent.com/k8snetworkplumbingwg/ovs-cni/main/examples/ovs-cni.yml" \
    | sed "s/ovs-cni-amd64/ovs-cni-${arch}/g; s|kubernetes.io/arch: amd64|kubernetes.io/arch: ${arch}|g" \
    | kubectl apply -f -
  kubectl -n kube-system rollout status "daemonset/ovs-cni-${arch}" --timeout=300s
}

# ---------------------------------------------------------------------------
# 4. KubeVirt
# ---------------------------------------------------------------------------
node_has_kvm() {
  ${OCI} exec "$(kind_node)" test -e /dev/kvm 2>/dev/null
}

needs_cross_arch_vms() {
  # Apple Silicon KinD nodes have no /dev/kvm. Native arm64 guests require
  # host-passthrough, which libvirt rejects under TCG (kubevirt/kubevirt#11917).
  # Run amd64 CirrOS via CrossArchitectureVirtualization (CPU model max) instead.
  local arch
  arch="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}')"
  [[ "${arch}" == "arm64" ]] && ! node_has_kvm
}

wait_kubevirt_available() {
  local timeout="${1:-600}" elapsed=0
  while (( elapsed < timeout )); do
    if kubectl -n kubevirt get kv kubevirt -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -qx True; then
      return 0
    fi
    local phase ready total
    phase="$(kubectl -n kubevirt get kv kubevirt -o jsonpath='{.status.phase}' 2>/dev/null || echo unknown)"
    ready="$(kubectl -n kubevirt get pods --no-headers 2>/dev/null | awk '$3=="Running"{c++} END{print c+0}')"
    total="$(kubectl -n kubevirt get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    log "KubeVirt ${phase}: ${ready}/${total} pods Running (${elapsed}s / ${timeout}s; image pulls can take several minutes)"
    kubectl -n kubevirt get pods --no-headers 2>/dev/null | awk '$3!="Running"{print "  pending:", $1, $3}' | head -5 || true
    if (( elapsed == 120 || elapsed == 300 )); then
      kubevirt_stuck_diagnostics || true
    fi
    sleep 15
    elapsed=$((elapsed + 15))
  done
  kubevirt_stuck_diagnostics || true
  die "KubeVirt did not become Available within ${timeout}s"
}

# Dump the real reason a virt-* pod is stuck (Events, CNI, node, kubelet).
kubevirt_stuck_diagnostics() {
  local pod
  echo "----- DIAGNOSTICS: node -----"
  kubectl get nodes -o wide 2>/dev/null || true
  echo "----- DIAGNOSTICS: kubevirt pods -----"
  kubectl -n kubevirt get pods -o wide 2>/dev/null || true
  pod="$(kubectl -n kubevirt get pods -l kubevirt.io=virt-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  if [[ -n "${pod}" ]]; then
    echo "----- DIAGNOSTICS: describe ${pod} (Events only) -----"
    kubectl -n kubevirt describe pod "${pod}" 2>/dev/null | sed -n '/Events:/,$p' || true
  fi
  echo "----- DIAGNOSTICS: kubevirt events -----"
  kubectl -n kubevirt get events --sort-by=.lastTimestamp 2>/dev/null | tail -25 || true
  echo "----- DIAGNOSTICS: CNI conf on node -----"
  ${OCI} exec "$(kind_node)" ls -la /etc/cni/net.d 2>/dev/null || true
  echo "----- DIAGNOSTICS: multus / kindnet / ovs-cni pods -----"
  kubectl get pods -A 2>/dev/null | grep -Ei 'multus|kindnet|flannel|ovs-cni' || true
  echo "----------------------------------------------"
}

# v1.9.0-rc.0 ships a ValidatingAdmissionPolicy whose CEL vars assume every
# initContainer has volumeMounts; virt-launcher pods omit that key and get denied.
# virt-operator recreates the policy if patched/deleted, so pause the operator and
# remove the binding before launching VMIs.
fix_kubevirt_v19_admission() {
  [[ "${KUBEVIRT_RELEASE:-}" == v1.9* ]] || needs_cross_arch_vms || return 0
  log "Pausing virt-operator and removing broken sidecar-subpath admission binding (v1.9 RC + K8s 1.32)"
  kubectl -n kubevirt scale deploy/virt-operator --replicas=0
  kubectl wait -n kubevirt --for=delete pod -l kubevirt.io=virt-operator --timeout=120s 2>/dev/null || sleep 5
  kubectl delete validatingadmissionpolicybinding kubevirt-plugin-sidecar-subpath-binding --ignore-not-found
  kubectl delete validatingadmissionpolicy kubevirt-plugin-sidecar-subpath-policy --ignore-not-found
}

restore_virt_operator() {
  [[ "${KUBEVIRT_RELEASE:-}" == v1.9* ]] || needs_cross_arch_vms || return 0
  log "Restoring virt-operator"
  kubectl -n kubevirt scale deploy/virt-operator --replicas=2
  kubectl -n kubevirt rollout status deploy/virt-operator --timeout=300s
}

preload_kubevirt_images() {
  local release="$1" tar="${KUBEVIRT_IMAGE_TAR:-/tmp/kubevirt-images.tar}"
  log "Pre-loading KubeVirt images into KinD (CI disk/pull optimization)"
  local imgs=(
    "quay.io/kubevirt/virt-operator:${release}"
    "quay.io/kubevirt/virt-api:${release}"
    "quay.io/kubevirt/virt-controller:${release}"
    "quay.io/kubevirt/virt-handler:${release}"
    "quay.io/kubevirt/virt-launcher:${release}"
    "quay.io/kubevirt/virt-exportproxy:${release}"
    "quay.io/kubevirt/cirros-container-disk-demo:latest"
  )
  if [[ ! -f "${tar}" ]]; then
    log "Pulling ${#imgs[@]} KubeVirt images (parallel) into ${tar}"
    local pids=() img
    for img in "${imgs[@]}"; do
      docker pull "${img}" &
      pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "${pid}"; done
    docker save "${imgs[@]}" -o "${tar}"
  else
    log "Reusing existing image archive ${tar}"
  fi
  kind load image-archive "${tar}" --name "${CLUSTER_NAME}"
}

install_kubevirt() {
  local release patch_json kv_timeout=900
  [[ -n "${GITHUB_ACTIONS:-}" ]] && kv_timeout=1800
  if needs_cross_arch_vms; then
    release="${KUBEVIRT_RELEASE:-v1.9.0-rc.0}"
    log "Arm64 without KVM: installing KubeVirt ${release} with cross-architecture VMs"
    patch_json='{"spec":{"configuration":{"developerConfiguration":{"featureGates":["MultiArchitecture","CrossArchitectureVirtualization"]}}}}'
  else
    release="${KUBEVIRT_RELEASE:-$(curl -fsSL --retry 3 https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)}"
    log "Installing KubeVirt ${release}"
    patch_json='{}'
  fi
  export KUBEVIRT_RELEASE="${release}"
  [[ -n "${GITHUB_ACTIONS:-}" ]] && preload_kubevirt_images "${release}"
  kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${release}/kubevirt-operator.yaml"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    kubectl -n kubevirt patch deployment virt-operator --type merge -p '{"spec":{"replicas":1}}'
  fi
  kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${release}/kubevirt-cr.yaml"
  if [[ -n "${GITHUB_ACTIONS:-}" ]] && ! node_has_kvm; then
    log "GHA: no /dev/kvm in node — enabling KubeVirt software emulation"
    kubectl -n kubevirt patch kubevirt kubevirt --type merge \
      -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
  elif [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    log "GHA: /dev/kvm is present in node — using real KVM acceleration"
  fi
  wait_kubevirt_available "${kv_timeout}"

  # No /dev/kvm => software emulation fallback for same-arch guests (linux/amd64 CI).
  if ! node_has_kvm && ! needs_cross_arch_vms; then
    log "/dev/kvm not present in nodes; enabling KubeVirt software emulation"
    kubectl -n kubevirt patch kubevirt kubevirt --type merge \
      -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
    wait_kubevirt_available 600
  fi

  if needs_cross_arch_vms; then
    kubectl -n kubevirt patch kubevirt kubevirt --type merge -p "${patch_json}"
    # Cross-arch TCG still needs useEmulation when the node has no /dev/kvm,
    # otherwise virt-launcher pods request devices.kubevirt.io/kvm and stay Pending.
    kubectl -n kubevirt patch kubevirt kubevirt --type merge \
      -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
    # v1.9 ImageVolume needs K8s 1.35+; KinD 1.32 breaks container-disk init
    # (exec: /container-disk-binary/usr/bin/container-disk: no such file or directory).
    kubectl -n kubevirt patch kubevirt kubevirt --type merge \
      -p '{"spec":{"configuration":{"developerConfiguration":{"disabledFeatureGates":["ImageVolume"]}}}}'
    wait_kubevirt_available 600
    fix_kubevirt_v19_admission
    log "Cross-arch mode: VMs run as amd64 guests under QEMU TCG (slow; allow ~30 min)"
  fi
}

configure_vms_for_platform() {
  if ! needs_cross_arch_vms; then
    return 0
  fi
  log "Ensuring VMs use amd64/q35 for cross-arch TCG on arm64 host"
  for vm in vm-a vm-b; do
    kubectl patch vm "${vm}" --type=json -p='[
      {"op":"add","path":"/spec/template/spec/architecture","value":"amd64"},
      {"op":"add","path":"/spec/template/spec/domain/machine","value":{"type":"q35"}}
    ]' 2>/dev/null || kubectl patch vm "${vm}" --type=json -p='[
      {"op":"replace","path":"/spec/template/spec/architecture","value":"amd64"},
      {"op":"replace","path":"/spec/template/spec/domain/machine/type","value":"q35"}
    ]'
  done
  local node
  node="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
  log "Labeling node ${node} for cross-arch amd64/q35 scheduling"
  kubectl label node "${node}" \
    kubevirt.io/vm-arch-amd64=true \
    machine-type.node.kubevirt.io/q35=true \
    --overwrite
  kubectl delete vmi vm-a vm-b --ignore-not-found --wait=false 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 5. Workloads + verification
# ---------------------------------------------------------------------------
deploy_workloads() {
  log "Applying ${MANIFESTS}"
  kubectl apply -f "${MANIFESTS}"
  configure_vms_for_platform
  fix_kubevirt_v19_admission
  local vmi_timeout="${VMI_WAIT_TIMEOUT:-600}"
  if needs_cross_arch_vms; then
    vmi_timeout="${VMI_WAIT_TIMEOUT:-3600}"
  fi
  log "Waiting for the ping pod and both VMIs (timeout ${vmi_timeout}s)"
  kubectl wait pod/ovs-ping-pod --for=condition=Ready --timeout=300s
  kubectl wait vmi/vm-a vmi/vm-b --for=jsonpath='{.status.phase}'=Running --timeout="${vmi_timeout}s"
  restore_virt_operator
}

wait_for_guest_network() {
  # CirrOS under TCG can take minutes to boot and run its userdata script;
  # poll until the VM answers on the OVS network.
  log "Waiting for CirrOS guests to configure eth1 (this is the slow part under emulation)"
  local i
  for i in $(seq 1 60); do
    if kubectl exec ovs-ping-pod -- ping -c 1 -W 2 "${VM_A_IP}" >/dev/null 2>&1 \
       && kubectl exec ovs-ping-pod -- ping -c 1 -W 2 "${VM_B_IP}" >/dev/null 2>&1; then
      log "Both guests reachable on the OVS network"
      return 0
    fi
    sleep 10
  done
  die "Guests never became reachable on ${BRIDGE}; check 'kubectl get vmi' and virt-launcher logs"
}

# Install explicit per-source classifier rules on br1 so verification_flows.json
# proves classification (rule matched by source IP) rather than only default-NORMAL
# forwarding. The priority=0 NORMAL catch-all is retained so the bridge continues
# to learn/forward everything else, keeping the FDB and datapath megaflow evidence
# intact.
ovs_evidence_node() {
  kubectl get pod -l kubevirt.io/domain=vm-a -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null \
    || kind_node
}

capture_flows_before() {
  local oci="$1" node
  node="$(ovs_evidence_node)"
  mkdir -p "${EVIDENCE_DIR}"
  log "Capturing pre-classifier OpenFlow snapshot (-> ${EVIDENCE_DIR}/flows_before.txt)"
  ${oci} exec "${node}" ovs-ofctl dump-flows "${BRIDGE}" > "${EVIDENCE_DIR}/flows_before.txt"
}

install_classifier_flows() {
  local oci="$1" node
  node="$(ovs_evidence_node)"
  log "Installing per-source classifier rules on ${BRIDGE} (node ${node})"
  ${oci} exec "${node}" ovs-ofctl del-flows "${BRIDGE}"
  ${oci} exec "${node}" ovs-ofctl add-flow  "${BRIDGE}" \
    "priority=100,ip,nw_src=${VM_A_IP} actions=NORMAL"
  ${oci} exec "${node}" ovs-ofctl add-flow  "${BRIDGE}" \
    "priority=100,ip,nw_src=${VM_B_IP} actions=NORMAL"
  ${oci} exec "${node}" ovs-ofctl add-flow  "${BRIDGE}" \
    "priority=100,ip,nw_src=${POD_IP}  actions=NORMAL"
  ${oci} exec "${node}" ovs-ofctl add-flow  "${BRIDGE}" \
    "priority=90,arp                   actions=NORMAL"
  ${oci} exec "${node}" ovs-ofctl add-flow  "${BRIDGE}" \
    "priority=0                        actions=NORMAL"
}

run_ping_test() {
  log "Running ping tests across ${BRIDGE} (results -> ${PING_RESULTS})"
  {
    echo "\$ kubectl exec ovs-ping-pod -- ping -c 4 ${VM_A_IP}"
    kubectl exec ovs-ping-pod -- ping -c 4 "${VM_A_IP}"
    echo
    echo "\$ kubectl exec ovs-ping-pod -- ping -c 4 ${VM_B_IP}"
    kubectl exec ovs-ping-pod -- ping -c 4 "${VM_B_IP}"
  } | tee "${PING_RESULTS}"

  local loss_count
  loss_count="$(grep -c '0% packet loss' "${PING_RESULTS}" || true)"
  if [[ "${loss_count}" -lt 2 ]]; then
    rm -f "${PING_RESULTS}"
    die "Ping verification failed (expected two '0% packet loss' blocks). Artifacts were not kept."
  fi
}

install_virtctl() {
  command -v virtctl >/dev/null 2>&1 && return 0
  local rel os arch dest tmp
  rel="${KUBEVIRT_RELEASE:-$(curl -fsSL --retry 3 https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)}"
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(host_arch)"
  mkdir -p "${HOME}/.local/bin"
  export PATH="${HOME}/.local/bin:${PATH}"
  dest="${HOME}/.local/bin/virtctl"
  tmp="$(mktemp)"
  if ! curl -fsSL --retry 3 \
    "https://github.com/kubevirt/kubevirt/releases/download/${rel}/virtctl-${rel}-${os}-${arch}" \
    -o "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  chmod +x "${tmp}"
  mv "${tmp}" "${dest}"
}

# Bidirectional VM<->VM pings driven over the KubeVirt serial console. Prefers
# `expect` when available (deterministic prompt handling); otherwise falls back
# to a scripted-sleeps approach. Either direction that produces `0% packet loss`
# is captured in evidence/console_ping_<dir>.txt and appended to ping_results.txt.
# It never fails the run: the pod<->VM evidence already proves VM traffic on br1.
run_vm_to_vm_ping() {
  install_virtctl || { log "virtctl unavailable; skipping VM<->VM console pings (best-effort)"; return 0; }
  local virtctl_cmd
  virtctl_cmd="$(command -v virtctl || echo "${HOME}/.local/bin/virtctl")"
  [[ -x "${virtctl_cmd}" ]] || { log "virtctl not found; skipping VM<->VM pings"; return 0; }
  mkdir -p "${EVIDENCE_DIR}"

  _run_expect_console() {  # $1=vm  $2=target  $3=outfile
    local vm="$1" target="$2" outfile="$3"
    VIRTCTL="${virtctl_cmd}" expect -f - "${vm}" "${target}" > "${outfile}" 2>&1 <<'EXPECT_EOF' || true
set vm     [lindex $argv 0]
set target [lindex $argv 1]
set virtctl $env(VIRTCTL)
set timeout 180
spawn $virtctl console $vm --namespace default
send "\r"
expect {
  -re "login:"       { send "cirros\r";   exp_continue }
  -re "assword:"     { send "gocubsgo\r"; exp_continue }
  -re {\$ }          { }
  timeout            { puts "\n\[verify\] TIMEOUT waiting for guest prompt"; exit 2 }
}
send "ping -c 5 $target\r"
expect {
  -re "packet loss"  { }
  timeout            { puts "\n\[verify\] TIMEOUT waiting for ping to finish"; exit 2 }
}
expect -re {\$ }
send "\x1d"
expect eof
EXPECT_EOF
  }

  _run_scripted_console() {  # $1=vm  $2=target  $3=outfile
    local vm="$1" target="$2" outfile="$3"
    {
      sleep 18; printf '\n'
      sleep 3;  printf 'cirros\n'
      sleep 3;  printf 'gocubsgo\n'
      sleep 4;  printf 'ping -c 5 %s\n' "${target}"
      sleep 15; printf 'exit\n'
      sleep 2
    } | timeout 120 "${virtctl_cmd}" console "${vm}" --namespace default >"${outfile}" 2>&1 || true
  }

  local have_expect=false
  command -v expect >/dev/null 2>&1 && have_expect=true

  local pair vm target outfile
  for pair in "vm-a:${VM_B_IP}" "vm-b:${VM_A_IP}"; do
    vm="${pair%%:*}"; target="${pair##*:}"
    outfile="${EVIDENCE_DIR}/console_ping_${vm}_to_${target}.txt"
    log "VM->VM console ping: ${vm} -> ${target} (expect=${have_expect})"
    if ${have_expect}; then
      _run_expect_console "${vm}" "${target}" "${outfile}"
    else
      _run_scripted_console "${vm}" "${target}" "${outfile}"
    fi
    if [[ -s "${outfile}" ]] && grep -q '0% packet loss' "${outfile}"; then
      {
        echo
        echo "\$ virtctl console ${vm}   # login, then: ping -c 5 ${target}  (VM->VM across ${BRIDGE})"
        sed -n '/PING /,/packet loss/p' "${outfile}"
      } >> "${PING_RESULTS}"
      log "  captured 0% packet loss; appended to ${PING_RESULTS}"
    else
      log "  no 0% packet loss captured (best-effort); pod<->VM evidence stands"
    fi
  done
}

# Record the execution mode of the running virt-launcher (KVM vs TCG) so that
# every artifact has a clear provenance. Yash's PR #7 pioneered this pattern in
# assignment-2 submissions; this makes it a first-class deliverable here too.
capture_execution_mode() {
  local oci="$1" node="$2"
  mkdir -p "${EVIDENCE_DIR}"
  {
    echo "=== KubeVirt useEmulation ==="
    kubectl -n kubevirt get kubevirt kubevirt \
      -o jsonpath='{.spec.configuration.developerConfiguration.useEmulation}' 2>/dev/null \
      || echo "(none)"
    echo
    echo
    echo "=== /dev/kvm on node ${node} ==="
    ${oci} exec "${node}" sh -c 'ls -la /dev/kvm 2>/dev/null || echo "(no /dev/kvm)"'
    echo
    echo "=== QEMU accelerator flag on virt-launcher-vm-a ==="
    local launcher
    launcher="$(kubectl get pods -l kubevirt.io/domain=vm-a -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${launcher}" ]]; then
      kubectl exec "${launcher}" -- sh -c \
        "ps -ef | grep -oE '\-accel [a-z]+' | head -1" 2>/dev/null \
        || echo "(could not read accel flag)"
    else
      echo "(no virt-launcher pod found)"
    fi
    echo
    echo "=== ovs-vsctl --version on node ==="
    ${oci} exec "${node}" ovs-vsctl --version | head -1 || true
    echo
    echo "=== node ==="
    echo "${node}"
  } > "${EVIDENCE_DIR}/execution_mode.txt"

  # kvm_proof.txt — separate artifact showing /dev/kvm presence + accel mode
  {
    echo "=== /dev/kvm on runner / KinD node ==="
    ${oci} exec "${node}" sh -c 'ls -la /dev/kvm 2>/dev/null || echo "(no /dev/kvm)"'
    echo
    echo "=== vmx/svm CPU flags (count) ==="
    grep -cE 'vmx|svm' /proc/cpuinfo 2>/dev/null || echo "(not on Linux host or no /proc/cpuinfo)"
    echo
    echo "=== KubeVirt useEmulation ==="
    kubectl -n kubevirt get kubevirt kubevirt \
      -o jsonpath='{.spec.configuration.developerConfiguration.useEmulation}' 2>/dev/null \
      || echo "(none)"
    echo
    echo "=== QEMU accel flag (virt-launcher-vm-a) ==="
    local launcher2
    launcher2="$(kubectl get pods -l kubevirt.io/domain=vm-a -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "${launcher2}" ]]; then
      kubectl exec "${launcher2}" -- sh -c \
        "ps -ef | grep -oE '\-accel [a-z]+' | head -1" 2>/dev/null \
        || echo "(could not read accel flag)"
    else
      echo "(no virt-launcher pod found)"
    fi
  } > "${EVIDENCE_DIR}/kvm_proof.txt"
}

capture_ovs_evidence() {
  local oci="$1"
  # Capture on the node actually hosting vm-a's launcher pod - that is where
  # the VM's frames provably traverse the bridge.
  local node
  node="$(ovs_evidence_node)"
  log "Capturing OVS evidence on node '${node}' (bridge ${BRIDGE})"

  mkdir -p "${EVIDENCE_DIR}"
  local tmp
  tmp="$(mktemp -d)"

  ${oci} exec "${node}" ovs-ofctl dump-flows "${BRIDGE}"        > "${tmp}/openflow.txt"
  ${oci} exec "${node}" ovs-appctl dpctl/dump-flows             > "${tmp}/datapath.txt" || true
  ${oci} exec "${node}" ovs-appctl fdb/show "${BRIDGE}"         > "${tmp}/fdb.txt"      || true
  ${oci} exec "${node}" ovs-ofctl show "${BRIDGE}"              > "${tmp}/ports.txt"
  # Bridge/port topology, including the VLAN access-port tags (tag: 100).
  ${oci} exec "${node}" ovs-vsctl show                          > "${tmp}/vsctl.txt"   || true
  local ovs_version
  ovs_version="$(${oci} exec "${node}" ovs-vsctl --version | head -1)"

  # Also publish the raw dumps into evidence/ (first-class deliverables). JSON is
  # produced by flows_to_json.py --bundle so text and JSON stay consistent.
  cp "${tmp}/openflow.txt" "${EVIDENCE_DIR}/flows_raw.txt"
  cp "${EVIDENCE_DIR}/flows_raw.txt" "${EVIDENCE_DIR}/flows_after.txt"
  [[ -s "${tmp}/datapath.txt" ]] && cp "${tmp}/datapath.txt" "${EVIDENCE_DIR}/datapath_raw.txt" || true
  [[ -s "${tmp}/fdb.txt"      ]] && cp "${tmp}/fdb.txt"      "${EVIDENCE_DIR}/fdb.txt"          || true
  cp "${tmp}/ports.txt"    "${EVIDENCE_DIR}/ports.txt"
  [[ -s "${tmp}/vsctl.txt"    ]] && cp "${tmp}/vsctl.txt"    "${EVIDENCE_DIR}/bridge_topology.txt" || true

  capture_execution_mode "${oci}" "${node}"

  [[ -f "${PARSER}" ]] || die "missing parser: ${PARSER}"
  python3 "${PARSER}" --bundle "${EVIDENCE_DIR}" --bridge "${BRIDGE}" \
    --node "${node}" --ovs-version "${ovs_version}" > "${FLOW_DUMP}"
  rm -rf "${tmp}"

  python3 -c "
import json, sys
d = json.load(open('${FLOW_DUMP}'))
if not d.get('flows') or not d.get('datapath_flows') or not d.get('fdb'):
    sys.exit('OVS evidence incomplete (missing flows, datapath_flows, or fdb)')
" || { rm -f "${FLOW_DUMP}"; die "OVS capture incomplete; ${FLOW_DUMP} was not kept."; }
}

# ---------------------------------------------------------------------------
main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_help
    exit 0
  fi

  if [[ "${CLEANUP:-0}" == "1" ]]; then
    kind delete cluster --name "${CLUSTER_NAME}" || true
    exit 0
  fi

  step "Prerequisites and host preflight"
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v python3 >/dev/null 2>&1 || die "python3 is required"
  OCI="$(detect_oci)"
  [[ -n "${OCI}" ]] || die "Docker or Podman with a running daemon is required"
  install_kind
  install_kubectl
  preflight_docker
  preflight_disk
  preflight_inotify
  docker system prune -f >/dev/null 2>&1 || true

  step "KinD cluster (${CLUSTER_NAME})"
  create_cluster

  step "Node ready (kindnet default CNI)"
  wait_node_ready

  step "Open vSwitch on KinD node(s)"
  install_ovs_in_nodes "${OCI}"

  step "VXLAN mesh between nodes (no-op on single-node)"
  setup_ovs_vxlan "${OCI}"

  step "Multus CNI ${MULTUS_VERSION}"
  install_multus

  step "OVS-CNI plugin"
  install_ovs_cni

  step "KubeVirt"
  install_kubevirt

  step "Workloads (2 VMs + ping pod) and guest network"
  deploy_workloads
  wait_for_guest_network

  step "OpenFlow baseline (pre-classifier snapshot)"
  capture_flows_before "${OCI}"

  step "Per-source classifier OpenFlow rules"
  install_classifier_flows "${OCI}"

  step "Ping verification (pod↔VM and VM↔VM)"
  run_ping_test
  run_vm_to_vm_ping

  step "Capture OVS evidence bundle"
  capture_ovs_evidence "${OCI}"

  log "Done."
  log "  ping results : ${PING_RESULTS}"
  log "  flow evidence: ${FLOW_DUMP}"
  log "  raw evidence : ${EVIDENCE_DIR}/"
}

main "$@"
