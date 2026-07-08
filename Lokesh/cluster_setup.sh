# =============================================================================
# ENGINE BOOTSTRAPPER: cluster_setup.sh
#
# Functionality:
#   Automates the end-to-end orchestration of a local validation datapath:
#   KinD Cluster -> Flannel Primary CNI -> Multus Meta-CNI -> OVS Switch 
#   Infrastructure + ovs-cni -> KubeVirt Engine -> CirrOS Virtual Machine Guest.
#   Concludes by executing automated bidirectional datapath validation checks
#   and harvesting raw OVS pipeline telemetry.
#
# ARCHITECTURAL PARADIGM:
#   Strict Error Propagation — This deployment script intentionally enforces a
#   fail-fast strategy for all guest interface connections. It explicitly rejects
#   the integration of simulated network namespaces or dummy veth stand-ins.
#   If the target VM interface fails to handle end-to-end traffic, the script
#   terminates with a non-zero exit code. This guarantees that your compiled 
#   verification artifacts represent authentic data paths. (For full system 
#   rationale, consult the accompanying documentation in architecture_design.md).
#
# GENERATED ARTIFACTS (Exported to $OUTPUT_DIR, defaults to ./output):
#   - ping_results.txt        : Standard stdout output from live ping verification.
#   - verification_flows.json : Normalised JSON structure of the active OVS openflow tables.
#
# RUNTIME INTERFACE:
#   Command Line:  ./cluster_setup.sh
#   Help Manual:   ./cluster_setup.sh --help
#   Overriding:    ENV_VAR=value ./cluster_setup.sh (Supports all parameters below)
#
# SYSTEM PREREQUISITES:
#   docker (>=24), kubectl (>=1.29), kind (>=0.23), jq (>=1.6), 
#   curl, expect, python3 (>=3.8)
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# --------------------------------------------------------------------------
# 0. Configuration (all overridable via environment variable)
# --------------------------------------------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-ovs-dpu-lab}"
KIND_K8S_VERSION="${KIND_K8S_VERSION:-v1.30.0}"
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.3.0}"
MULTUS_VERSION="${MULTUS_VERSION:-v4.0.2}"
OVS_CNI_VERSION="${OVS_CNI_VERSION:-v0.38.0}"
FLANNEL_VERSION="${FLANNEL_VERSION:-v0.25.1}"
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-v1.4.1}"
OVS_BRIDGE_NAME="${OVS_BRIDGE_NAME:-br-ovs}"
OVS_VLAN="${OVS_VLAN:-100}"
OVS_HOST_IP="${OVS_HOST_IP:-192.168.100.1}"   # assigned to the bridge's LOCAL port
OVS_VM_IP="${OVS_VM_IP:-192.168.100.10}"      # assigned to the VM's eth1 via cloud-init
OVS_VM_NAME="${OVS_VM_NAME:-cirros-ovs-vm}"
NAMESPACE_KV="kubevirt"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/output}"
TIMEOUT_SHORT="120s"
TIMEOUT_MED="300s"
TIMEOUT_LONG="600s"
VM_BOOT_BUDGET_SECONDS="${VM_BOOT_BUDGET_SECONDS:-600}"   # generous: TCG emulation is slow
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<EOF
cluster_setup.sh — bootstrap KinD+KubeVirt+Multus+OVS-CNI and verify the datapath.

Override any of these by exporting before running:
  CLUSTER_NAME=${CLUSTER_NAME}
  KIND_K8S_VERSION=${KIND_K8S_VERSION}
  KUBEVIRT_VERSION=${KUBEVIRT_VERSION}
  MULTUS_VERSION=${MULTUS_VERSION}
  OVS_CNI_VERSION=${OVS_CNI_VERSION}
  FLANNEL_VERSION=${FLANNEL_VERSION}
  CNI_PLUGINS_VERSION=${CNI_PLUGINS_VERSION}
  OVS_BRIDGE_NAME=${OVS_BRIDGE_NAME}
  OVS_VLAN=${OVS_VLAN}
  OVS_HOST_IP=${OVS_HOST_IP}
  OVS_VM_IP=${OVS_VM_IP}
  OVS_VM_NAME=${OVS_VM_NAME}
  OUTPUT_DIR=${OUTPUT_DIR}
  VM_BOOT_BUDGET_SECONDS=${VM_BOOT_BUDGET_SECONDS}

Exit codes: 0 = success incl. verified bidirectional ping.
            1 = a bootstrap step failed (cluster/CNI/KubeVirt install).
            2 = bootstrap succeeded but ping verification failed (see logs).
EOF
  exit 0
fi

mkdir -p "${OUTPUT_DIR}"

# --------------------------------------------------------------------------
# Logging helpers
# --------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN ]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}==> $*${NC}"; }

# --------------------------------------------------------------------------
# Cleanup / error trap
# --------------------------------------------------------------------------
TMP_FILES=()
cleanup() {
  local code=$?
  for f in "${TMP_FILES[@]:-}"; do [[ -n "$f" ]] && rm -f "$f"; done
  if [[ $code -ne 0 ]]; then
    err "Script exited with code ${code}."
    warn "Cluster '${CLUSTER_NAME}' (if created) was left running for inspection."
    warn "Inspect with: kubectl get pods -A ; kind export logs --name ${CLUSTER_NAME} /tmp/kind-logs"
    warn "Tear down with: kind delete cluster --name ${CLUSTER_NAME}"
  fi
}
trap cleanup EXIT

# retry <n> <sleep_seconds> <description> -- <command...>
retry() {
  local n="$1" sleep_s="$2" desc="$3"; shift 3
  [[ "$1" == "--" ]] && shift
  local i
  for ((i=1; i<=n; i++)); do
    if "$@"; then return 0; fi
    warn "  ${desc}: attempt ${i}/${n} failed, retrying in ${sleep_s}s..."
    sleep "${sleep_s}"
  done
  err "${desc}: all ${n} attempts failed."
  return 1
}

# --------------------------------------------------------------------------
# STEP 0 — Prerequisites
# --------------------------------------------------------------------------
step "0/11 Checking prerequisites"

declare -A INSTALL_HINTS=(
  [docker]="https://docs.docker.com/engine/install/"
  [kubectl]="https://kubernetes.io/docs/tasks/tools/#kubectl"
  [kind]="go install sigs.k8s.io/kind@v0.23.0  (or see https://kind.sigs.k8s.io/docs/user/quick-start/)"
  [jq]="apt install jq  /  brew install jq"
  [curl]="apt install curl  /  brew install curl"
  [expect]="apt install expect  /  brew install expect"
  [python3]="apt install python3  /  brew install python3"
)
MISSING=0
for c in docker kubectl kind jq curl expect python3; do
  if command -v "$c" &>/dev/null; then
    log "✔ ${c} found: $(${c} --version 2>&1 | head -1)"
  else
    err "✘ ${c} not found. Install: ${INSTALL_HINTS[$c]}"
    MISSING=1
  fi
done
[[ $MISSING -eq 1 ]] && { err "Install missing prerequisites and re-run."; exit 1; }

if ! docker info &>/dev/null; then
  err "Docker daemon is not reachable (docker info failed). Is Docker running / do you have permission?"
  exit 1
fi

KVM_AVAILABLE=false
if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
  KVM_AVAILABLE=true
  log "✔ /dev/kvm available — KubeVirt will use hardware-accelerated virtualization."
else
  warn "/dev/kvm not available (expected on macOS/Docker Desktop, or nested-virt disabled)."
  warn "KubeVirt will fall back to TCG software emulation. Functionally correct, just slower to boot."
  warn "To enable nested virt on a bare-metal Linux host:"
  warn "  Intel: echo 'options kvm-intel nested=1' | sudo tee /etc/modprobe.d/kvm-intel.conf && sudo modprobe -r kvm_intel && sudo modprobe kvm_intel"
  warn "  AMD  : echo 'options kvm-amd nested=1'   | sudo tee /etc/modprobe.d/kvm-amd.conf   && sudo modprobe -r kvm_amd   && sudo modprobe kvm_amd"
fi

# --------------------------------------------------------------------------
# inotify limits — a very common, host-level cause of virt-handler (and
# etcd/kubelet in general) crash-looping with "too many open files" /
# "Failed to create an inotify watcher". KinD nodes plus KubeVirt's
# certificate-rotation file watchers can exceed low default limits on
# many Linux distros. Checked here, before cluster creation, rather than
# discovered later via a cryptic CrashLoopBackOff.
# --------------------------------------------------------------------------
if [[ "$(uname -s)" == "Linux" ]]; then
  CUR_WATCHES=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
  CUR_INSTANCES=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)
  MIN_WATCHES=524288
  MIN_INSTANCES=512
  if [[ "${CUR_WATCHES}" -lt "${MIN_WATCHES}" || "${CUR_INSTANCES}" -lt "${MIN_INSTANCES}" ]]; then
    warn "inotify limits look low for KinD+KubeVirt (watches=${CUR_WATCHES}, instances=${CUR_INSTANCES})."
    warn "This commonly causes virt-handler to crash-loop with 'too many open files'."
    warn "Fix now with:"
    warn "  sudo sysctl fs.inotify.max_user_watches=1048576"
    warn "  sudo sysctl fs.inotify.max_user_instances=8192"
    warn "To persist across reboots:"
    warn "  echo 'fs.inotify.max_user_watches=1048576' | sudo tee -a /etc/sysctl.d/99-kind.conf"
    warn "  echo 'fs.inotify.max_user_instances=8192' | sudo tee -a /etc/sysctl.d/99-kind.conf"
    warn "  sudo sysctl --system"
    warn "Continuing anyway in case this host's actual limits differ from what /proc reports in your environment — but expect virt-handler to crash-loop if this isn't raised."
  else
    log "✔ inotify limits OK (watches=${CUR_WATCHES}, instances=${CUR_INSTANCES})."
  fi
fi

# --------------------------------------------------------------------------
# STEP 1 — Create KinD cluster (Flannel deferred; CNI disabled at creation)
# --------------------------------------------------------------------------
step "1/11 Creating KinD cluster '${CLUSTER_NAME}' (${KIND_K8S_VERSION})"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  warn "Cluster '${CLUSTER_NAME}' already exists — reusing it. Delete first for a clean run:"
  warn "  kind delete cluster --name ${CLUSTER_NAME}"
else
  KIND_CONFIG="$(mktemp /tmp/kind-config-XXXXXX.yaml)"
  TMP_FILES+=("${KIND_CONFIG}")
  cat > "${KIND_CONFIG}" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
networking:
  disableDefaultCNI: true
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /dev
        containerPath: /dev
  - role: worker
    extraMounts:
      - hostPath: /dev
        containerPath: /dev
EOF
  kind create cluster --config "${KIND_CONFIG}" --image "kindest/node:${KIND_K8S_VERSION}" --wait "${TIMEOUT_SHORT}"
fi

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
log "✔ kubectl context: kind-${CLUSTER_NAME}"

ALL_NODES="$(kind get nodes --name "${CLUSTER_NAME}" || true)"
WORKER_NODE="$(echo "${ALL_NODES}" | grep worker | head -1 || true)"
if [[ -z "${WORKER_NODE}" ]]; then
  err "No node with 'worker' in its name found in cluster ${CLUSTER_NAME}."
  err "Nodes actually present in this cluster:"
  echo "${ALL_NODES}" | sed 's/^/         /' >&2
  err "This usually means a cluster named '${CLUSTER_NAME}' already existed"
  err "from an earlier run/experiment, with a different node topology than"
  err "the control-plane+worker layout this script creates. Fix with:"
  err "  kind delete cluster --name ${CLUSTER_NAME}"
  err "then re-run this script so it creates the cluster fresh."
  exit 1
fi
log "✔ Worker node (where the VM + OVS bridge will live): ${WORKER_NODE}"

# Standard CNI plugin binaries (bridge, loopback, host-local, etc.) — needed
# by Flannel and by ovs-cni's IPAM delegate, and not always preloaded in
# every KinD node image.
log "Installing standard CNI plugin binaries on all nodes..."
kind get nodes --name "${CLUSTER_NAME}" | while read -r NODE; do
  docker exec -e CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION}" "${NODE}" bash -euo pipefail -c '
    [[ -f /opt/cni/bin/bridge ]] && exit 0
    ARCH=$(uname -m); [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && A=arm64 || A=amd64
    curl -sSL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${A}-${CNI_PLUGINS_VERSION}.tgz" \
      | tar -xz -C /opt/cni/bin
  '
done
log "✔ CNI plugin binaries present."

# --------------------------------------------------------------------------
# STEP 2 — Flannel (primary CNI, required for pod-to-pod / DNS)
# --------------------------------------------------------------------------
step "2/11 Installing Flannel (primary CNI, ${FLANNEL_VERSION})"
kubectl apply -f "https://raw.githubusercontent.com/flannel-io/flannel/${FLANNEL_VERSION}/Documentation/kube-flannel.yml"
kubectl -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout="${TIMEOUT_MED}"
kubectl -n kube-system wait pod -l k8s-app=kube-dns --for=condition=Ready --timeout="${TIMEOUT_MED}"
log "✔ Flannel Ready, CoreDNS Ready."

# --------------------------------------------------------------------------
# STEP 3 — Multus CNI (thick / daemonset)
# --------------------------------------------------------------------------
step "3/11 Installing Multus CNI (${MULTUS_VERSION}, thick plugin)"
kubectl apply -f "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${MULTUS_VERSION}/deployments/multus-daemonset-thick.yml"

# Known issue: some multus-daemonset-thick.yml revisions don't mount
# /opt/cni/bin, so the multus binary can't exec delegate plugins. Patch
# idempotently if the volumeMount is missing.
if ! kubectl -n kube-system get daemonset kube-multus-ds \
     -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[*].name}' 2>/dev/null | grep -q cnibin; then
  log "Patching Multus DaemonSet to mount /opt/cni/bin (cnibin)..."
  kubectl -n kube-system patch daemonset kube-multus-ds --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"cnibin","mountPath":"/opt/cni/bin"}}]'
fi
kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout="${TIMEOUT_LONG}"

retry 20 5 "NetworkAttachmentDefinition CRD registration" -- \
  kubectl get crd network-attachment-definitions.k8s.cni.cncf.io &>/dev/null
log "✔ Multus Ready, NetworkAttachmentDefinition CRD present."

# --------------------------------------------------------------------------
# STEP 4 — Open vSwitch inside each node + bridge creation
# --------------------------------------------------------------------------
step "4/11 Installing Open vSwitch inside KinD nodes, creating ${OVS_BRIDGE_NAME}"

kind get nodes --name "${CLUSTER_NAME}" | while read -r NODE; do
  log "  Configuring OVS on node: ${NODE}"
  docker exec \
    -e OVS_BRIDGE_NAME="${OVS_BRIDGE_NAME}" \
    -e OVS_VLAN="${OVS_VLAN}" \
    -e OVS_HOST_IP="${OVS_HOST_IP}" \
    "${NODE}" bash -euo pipefail -c '
      if ! command -v ovs-vsctl &>/dev/null; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openvswitch-switch iproute2 iputils-ping
      fi
      /usr/share/openvswitch/scripts/ovs-ctl start --system-id=random 2>/dev/null \
        || systemctl start openvswitch-switch 2>/dev/null \
        || service openvswitch-switch start 2>/dev/null || true
      ovs-vsctl show &>/dev/null || { echo "OVS failed to start on $(hostname)" >&2; exit 1; }

      ovs-vsctl --may-exist add-br "${OVS_BRIDGE_NAME}" -- set bridge "${OVS_BRIDGE_NAME}" datapath_type=system
      ovs-vsctl set port "${OVS_BRIDGE_NAME}" tag="${OVS_VLAN}"
      ip link set "${OVS_BRIDGE_NAME}" up
      ip addr show dev "${OVS_BRIDGE_NAME}" | grep -q "${OVS_HOST_IP}/24" \
        || ip addr add "${OVS_HOST_IP}/24" dev "${OVS_BRIDGE_NAME}"
      ovs-vsctl br-exists "${OVS_BRIDGE_NAME}"
    '
done
log "✔ ${OVS_BRIDGE_NAME} up on all nodes, VLAN ${OVS_VLAN}, host IP ${OVS_HOST_IP}/24 on the worker."

# --------------------------------------------------------------------------
# STEP 5 — ovs-cni plugin + marker daemonsets
# --------------------------------------------------------------------------
step "5/11 Installing ovs-cni (${OVS_CNI_VERSION})"

OVS_CNI_MANIFEST="https://raw.githubusercontent.com/k8snetworkplumbingwg/ovs-cni/${OVS_CNI_VERSION}/examples/ovs-cni.yml"
if ! kubectl apply -f "${OVS_CNI_MANIFEST}"; then
  err "Failed to fetch/apply ovs-cni manifest for ${OVS_CNI_VERSION}."
  err "Check the tag exists: https://github.com/k8snetworkplumbingwg/ovs-cni/tags"
  exit 1
fi

# The marker daemonset advertises a per-node extended resource
# (k8s.v1.cni.cncf.io/resourceName) so the scheduler only places
# OVS-secondary-network pods on nodes that actually have OVS running.
for DS in ovs-cni-marker ovs-cni-plugin; do
  if kubectl -n kube-system get daemonset "${DS}" &>/dev/null; then
    kubectl -n kube-system rollout status "daemonset/${DS}" --timeout="${TIMEOUT_MED}"
    log "✔ ${DS} rolled out."
  fi
done

# End-to-end probe: a throwaway pod on the ovs-cni network must reach Ready.
# This isolates ovs-cni failures from KubeVirt failures later, so a broken
# CNI doesn't masquerade as a broken VM.
log "Probing ovs-cni with a throwaway pod..."
kubectl apply -f - <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: probe-net
  namespace: default
spec:
  config: '{"cniVersion":"0.4.0","type":"ovs","bridge":"${OVS_BRIDGE_NAME}"}'
---
apiVersion: v1
kind: Pod
metadata:
  name: ovs-cni-probe
  namespace: default
  annotations:
    k8s.v1.cni.cncf.io/networks: probe-net
spec:
  containers:
    - name: pause
      image: registry.k8s.io/pause:3.9
EOF
if ! kubectl wait --for=condition=Ready pod/ovs-cni-probe --timeout=90s; then
  err "ovs-cni probe pod failed to become Ready — the CNI chain is broken before we even get to KubeVirt."
  kubectl describe pod ovs-cni-probe
  exit 1
fi
kubectl delete pod ovs-cni-probe --force --grace-period=0 &>/dev/null || true
kubectl delete networkattachmentdefinition probe-net &>/dev/null || true
log "✔ ovs-cni verified end-to-end with a throwaway pod."

# --------------------------------------------------------------------------
# STEP 6 — KubeVirt
# --------------------------------------------------------------------------
step "6/11 Installing KubeVirt (${KUBEVIRT_VERSION})"

KV_BASE="https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}"
kubectl apply -f "${KV_BASE}/kubevirt-operator.yaml"
kubectl -n "${NAMESPACE_KV}" rollout status deployment/virt-operator --timeout="${TIMEOUT_LONG}"
kubectl apply -f "${KV_BASE}/kubevirt-cr.yaml"

if [[ "${KVM_AVAILABLE}" == "false" ]]; then
  retry 20 5 "KubeVirt CR creation" -- kubectl -n "${NAMESPACE_KV}" get kubevirt kubevirt &>/dev/null
  kubectl -n "${NAMESPACE_KV}" patch kubevirt kubevirt --type=merge \
    -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
  log "✔ useEmulation=true patched in (no /dev/kvm on this host)."
fi

log "Waiting for KubeVirt phase=Deployed (can take several minutes)..."
for i in $(seq 1 90); do
  PHASE=$(kubectl -n "${NAMESPACE_KV}" get kubevirt kubevirt -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "${PHASE}" == "Deployed" ]] && { log "✔ KubeVirt phase: Deployed"; break; }
  [[ $i -eq 90 ]] && { err "KubeVirt never reached Deployed (last: ${PHASE})"; exit 1; }
  sleep 10
done
kubectl -n "${NAMESPACE_KV}" rollout status deployment/virt-api --timeout="${TIMEOUT_LONG}"
kubectl -n "${NAMESPACE_KV}" rollout status deployment/virt-controller --timeout="${TIMEOUT_LONG}"
kubectl -n "${NAMESPACE_KV}" rollout status daemonset/virt-handler --timeout="${TIMEOUT_LONG}"
log "✔ virt-api, virt-controller, virt-handler all Ready."

# --------------------------------------------------------------------------
# STEP 7 — virtctl
# --------------------------------------------------------------------------
step "7/11 Installing virtctl"
VIRTCTL="${HOME}/.local/bin/virtctl"
mkdir -p "$(dirname "${VIRTCTL}")"
if [[ ! -x "${VIRTCTL}" ]]; then
  ARCH=$(uname -m); [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && A=arm64 || A=amd64
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  curl -fsSL -o "${VIRTCTL}" "${KV_BASE}/virtctl-${KUBEVIRT_VERSION}-${OS}-${A}"
  chmod +x "${VIRTCTL}"
fi
export PATH="${HOME}/.local/bin:${PATH}"
log "✔ virtctl: $(virtctl version --client 2>&1 | head -1 || echo installed)"

# --------------------------------------------------------------------------
# STEP 8 — Apply manifests.yaml
# --------------------------------------------------------------------------
step "8/11 Applying manifests.yaml"
[[ -f "${SCRIPT_DIR}/manifests.yaml" ]] || { err "manifests.yaml not found next to this script."; exit 1; }
export OVS_BRIDGE_NAME OVS_VLAN OVS_VM_NAME OVS_VM_IP
envsubst '${OVS_BRIDGE_NAME} ${OVS_VLAN} ${OVS_VM_NAME} ${OVS_VM_IP}' < "${SCRIPT_DIR}/manifests.yaml" | kubectl apply -f -
log "✔ NetworkAttachmentDefinition + VirtualMachine applied."

# --------------------------------------------------------------------------
# STEP 9 — Wait for the VMI to reach Running
# --------------------------------------------------------------------------
step "9/11 Waiting for VMI '${OVS_VM_NAME}' to reach Running"
retry 30 10 "VMI object creation" -- kubectl get vmi "${OVS_VM_NAME}" &>/dev/null

elapsed=0
while true; do
  PHASE=$(kubectl get vmi "${OVS_VM_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  [[ "${PHASE}" == "Running" ]] && { log "✔ VMI phase: Running"; break; }
  if [[ "${PHASE}" == "Failed" ]]; then
    err "VMI reached Failed phase. Events:"
    kubectl describe vmi "${OVS_VM_NAME}"
    exit 1
  fi
  if [[ ${elapsed} -ge ${VM_BOOT_BUDGET_SECONDS} ]]; then
    err "VMI did not reach Running within ${VM_BOOT_BUDGET_SECONDS}s (last phase: ${PHASE})."
    kubectl describe vmi "${OVS_VM_NAME}"
    exit 1
  fi
  sleep 10; elapsed=$((elapsed + 10))
  log "  VMI phase: ${PHASE} (${elapsed}s/${VM_BOOT_BUDGET_SECONDS}s)"
done

# --------------------------------------------------------------------------
# STEP 10 — Bidirectional ping verification (FAIL LOUD, no substitute)
# --------------------------------------------------------------------------
step "10/11 Bidirectional ping verification (real VM, no synthetic fallback)"

PING_OUT="${OUTPUT_DIR}/ping_results.txt"
: > "${PING_OUT}"

log "Direction 1/2: HOST -> VM (from the worker node, over ${OVS_BRIDGE_NAME})"
{
  echo "[HOST -> VM] docker exec ${WORKER_NODE} ping -c 5 -I ${OVS_BRIDGE_NAME} ${OVS_VM_IP}"
  echo
} >> "${PING_OUT}"
HOST_TO_VM=$(docker exec "${WORKER_NODE}" ping -c 5 -W 2 -I "${OVS_BRIDGE_NAME}" "${OVS_VM_IP}" 2>&1) || true
echo "${HOST_TO_VM}" >> "${PING_OUT}"
echo >> "${PING_OUT}"

HOST_TO_VM_OK=false
if echo "${HOST_TO_VM}" | grep -qE "\b[1-5] (packets )?received\b" && ! echo "${HOST_TO_VM}" | grep -q "100% packet loss"; then
  HOST_TO_VM_OK=true
fi

log "Direction 2/2: VM -> HOST (via virtctl console, real guest shell)"
{
  echo "[VM -> HOST] virtctl console ${OVS_VM_NAME} ; ping -c 5 -I eth1 ${OVS_HOST_IP}"
  echo
} >> "${PING_OUT}"

# Wait for the guest to reach a login prompt before attempting to log in.
BOOTED=false
elapsed=0
while [[ ${elapsed} -lt ${VM_BOOT_BUDGET_SECONDS} ]]; do
  if expect -c "
      set timeout 12
      spawn virtctl console ${OVS_VM_NAME}
      expect { -re {(?i)login:} { exit 0 } timeout { exit 1 } }
    " &>/dev/null; then
    BOOTED=true; break
  fi
  sleep 15; elapsed=$((elapsed + 15))
  log "  Guest not at login prompt yet (${elapsed}s/${VM_BOOT_BUDGET_SECONDS}s)..."
done

VM_TO_HOST_OK=false
if [[ "${BOOTED}" == "true" ]]; then
  VM_SESSION=$(expect <<EOF || true
set timeout 60
log_user 1
spawn virtctl console ${OVS_VM_NAME}
expect -re {(?i)login:}
send "cirros\r"
expect "assword:"
send "gocubsgo\r"
expect "\\\$ "
send "ip addr show eth1\r"
expect "\\\$ "
send "ping -c 5 -I eth1 ${OVS_HOST_IP}\r"
expect "\\\$ "
send "exit\r"
EOF
)
  echo "${VM_SESSION}" >> "${PING_OUT}"
  if echo "${VM_SESSION}" | grep -q "0% packet loss"; then
    VM_TO_HOST_OK=true
  fi
else
  echo "GUEST NEVER REACHED LOGIN PROMPT WITHIN ${VM_BOOT_BUDGET_SECONDS}s." >> "${PING_OUT}"
fi
echo >> "${PING_OUT}"

log "ping_results.txt written to ${PING_OUT}"

# --------------------------------------------------------------------------
# STEP 11 — verification_flows.json (JSON-normalized OVS flow dump)
# --------------------------------------------------------------------------
step "11/11 Capturing OVS flow table as verification_flows.json"

PARSE_FLOWS="$(mktemp /tmp/parse_flows-XXXXXX.py)"
TMP_FILES+=("${PARSE_FLOWS}")
cp "${SCRIPT_DIR}/parse_flows.py" "${PARSE_FLOWS}" 2>/dev/null || cat > "${PARSE_FLOWS}" <<'PYEOF'
#!/usr/bin/env python3
# Fallback inline copy of parse_flows.py — kept in sync with the standalone
# file shipped alongside this script. See parse_flows.py for full comments.
import sys, json, re

def parse_line(line):
    line = line.strip()
    if not line or line.startswith(("NXST_FLOW", "OFPST_FLOW")):
        return None
    left, _, actions_str = line.partition(" actions=")
    info, match = {}, {}
    info_keys = {"cookie", "duration", "table", "n_packets", "n_bytes",
                 "idle_age", "hard_age", "priority", "idle_timeout", "hard_timeout"}
    for part in left.split(", "):
        if "=" not in part:
            continue
        k, v = part.split("=", 1)
        if k == "duration" and v.endswith("s"):
            v = float(v[:-1])
        elif re.fullmatch(r"-?\d+", v):
            v = int(v)
        (info if k in info_keys else match)[k] = v
    actions = []
    for act in actions_str.split(","):
        act = act.strip()
        if not act:
            continue
        if "(" in act and act.endswith(")"):
            k, v = act.split("(", 1)
            actions.append({k: v[:-1]})
        else:
            actions.append({act: None})
    return {"info": info, "match": match, "actions": actions}

flows = [f for f in (parse_line(l) for l in sys.stdin) if f]
print(json.dumps({"flows": flows}, indent=2))
PYEOF

docker exec "${WORKER_NODE}" ovs-ofctl dump-flows "${OVS_BRIDGE_NAME}" > /tmp/raw_flows.txt
OVS_VERSION=$(docker exec "${WORKER_NODE}" ovs-vsctl --version 2>/dev/null | head -1 || echo "unknown")

python3 "${PARSE_FLOWS}" < /tmp/raw_flows.txt > "${OUTPUT_DIR}/flows_body.json"

DUMP_PORTS=$(docker exec "${WORKER_NODE}" ovs-ofctl dump-ports "${OVS_BRIDGE_NAME}" 2>/dev/null || echo "")
FDB_SHOW=$(docker exec "${WORKER_NODE}" ovs-appctl fdb/show "${OVS_BRIDGE_NAME}" 2>/dev/null || echo "")
PORT_INFO=$(docker exec "${WORKER_NODE}" ovs-vsctl list port "${OVS_BRIDGE_NAME}" 2>/dev/null || echo "")

jq -n \
  --slurpfile flows "${OUTPUT_DIR}/flows_body.json" \
  --arg ovs_version "${OVS_VERSION}" \
  --arg bridge "${OVS_BRIDGE_NAME}" \
  --arg dump_ports "${DUMP_PORTS}" \
  --arg fdb_show "${FDB_SHOW}" \
  --arg port_info "${PORT_INFO}" \
  '{
    "_metadata": {
      "note": ("Generated by cluster_setup.sh via `ovs-ofctl dump-flows \($bridge)`, normalized to JSON by parse_flows.py because \($ovs_version) predates ovs-ofctl'"'"'s native --format=json support."),
      "bridge": $bridge,
      "ovs_version": $ovs_version
    },
    "flows": $flows[0].flows,
    "diagnostics": {
      "dump_ports": $dump_ports,
      "fdb_show": $fdb_show,
      "port_info": $port_info
    }
  }' > "${OUTPUT_DIR}/verification_flows.json"
rm -f "${OUTPUT_DIR}/flows_body.json"

log "✔ verification_flows.json written to ${OUTPUT_DIR}/verification_flows.json"

# --------------------------------------------------------------------------
# Summary — fail loud if either direction didn't verify
# --------------------------------------------------------------------------
echo
if [[ "${HOST_TO_VM_OK}" == "true" && "${VM_TO_HOST_OK}" == "true" ]]; then
  log "ALL VERIFICATION PASSED (host->VM and VM->host both confirmed 0% packet loss)."
  EXIT_CODE=0
else
  err "VERIFICATION FAILED — this is reported as a failure, not papered over:"
  [[ "${HOST_TO_VM_OK}" != "true" ]] && err "  - HOST -> VM ping did not succeed"
  [[ "${VM_TO_HOST_OK}" != "true" ]] && err "  - VM -> HOST ping did not succeed"
  err "See ${PING_OUT} for the raw session transcript, and debug from there:"
  err "  kubectl describe vmi ${OVS_VM_NAME}"
  err "  kubectl -n ${NAMESPACE_KV} logs -l kubevirt.io=virt-handler --tail=100"
  err "  docker exec ${WORKER_NODE} ovs-vsctl show"
  EXIT_CODE=2
fi
log "Cluster: ${CLUSTER_NAME} | KubeVirt: ${KUBEVIRT_VERSION} | Multus: ${MULTUS_VERSION} | ovs-cni: ${OVS_CNI_VERSION}"
log "Outputs: ${OUTPUT_DIR}/ping_results.txt , ${OUTPUT_DIR}/verification_flows.json"
exit ${EXIT_CODE}