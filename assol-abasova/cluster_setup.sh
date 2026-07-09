#!/usr/bin/env bash
# =============================================================================
# cluster_setup.sh — Hands-On Assignment 2: Cloud-Native OVS Datapath Challenge
#
# Bootstraps, on a single machine (Linux, or macOS with Docker Desktop):
#   1. A kind (Kubernetes-in-Docker) cluster
#   2. KubeVirt (emulation mode -> no KVM required, works on kind/macOS)
#   3. Multus CNI + OVS CNI (via the KubeVirt Cluster Network Addons Operator,
#      which is the upstream-supported way to deploy both)
#   4. Open vSwitch inside the kind node, with bridge br1
#      (datapath_type=netdev, i.e. userspace datapath, deliberately chosen so
#       the lab does not depend on the openvswitch kernel module being present
#       in Docker Desktop's VM kernel — see dpu_offload_concept.md §1)
#   5. A CirrOS VirtualMachine attached to br1 via a Multus
#      NetworkAttachmentDefinition (manifests.yaml)
#
# Then verifies the datapath and emits the assignment's raw outputs:
#   - ping_results.txt        (raw stdout of ping across the OVS bridge)
#   - verification_flows.json (raw `ovs-ofctl dump-flows br1 --format=json`;
#                              falls back to a JSON wrapping of the text dump
#                              when the node's OVS predates 3.1)
#
# Usage:   ./cluster_setup.sh            # full run
#          ./cluster_setup.sh teardown   # delete the cluster
#
# Requirements: docker (daemon running), curl. kind/kubectl are auto-installed
# into ./bin if missing. Give Docker Desktop >= 8 GB RAM for KubeVirt+TCG.
# =============================================================================
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ovs-lab}"
NODE="${CLUSTER_NAME}-control-plane"
BRIDGE="br1"
VM_IP="10.10.10.10"
GW_IP="10.10.10.1"
BIN_DIR="$(pwd)/bin"
export PATH="${BIN_DIR}:${PATH}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- teardown mode -----------------------------------------------------------
if [[ "${1:-}" == "teardown" ]]; then
  kind delete cluster --name "${CLUSTER_NAME}" || true
  exit 0
fi

# --- 0. prerequisites --------------------------------------------------------
log "Checking prerequisites"
command -v docker >/dev/null || die "docker not found — install Docker Desktop / docker engine"
docker info >/dev/null 2>&1 || die "docker daemon not running"
command -v curl >/dev/null || die "curl not found"
mkdir -p "${BIN_DIR}"

OS="$(uname | tr '[:upper:]' '[:lower:]')"   # linux | darwin
ARCH="$(uname -m)"; case "${ARCH}" in x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; esac

if ! command -v kind >/dev/null; then
  log "Installing kind into ${BIN_DIR}"
  curl -fsSLo "${BIN_DIR}/kind" \
    "https://kind.sigs.k8s.io/dl/latest/kind-${OS}-${ARCH}"
  chmod +x "${BIN_DIR}/kind"
fi
if ! command -v kubectl >/dev/null; then
  log "Installing kubectl into ${BIN_DIR}"
  KVER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSLo "${BIN_DIR}/kubectl" \
    "https://dl.k8s.io/release/${KVER}/bin/${OS}/${ARCH}/kubectl"
  chmod +x "${BIN_DIR}/kubectl"
fi

# --- 1. kind cluster ---------------------------------------------------------
log "Creating kind cluster '${CLUSTER_NAME}' (single node)"
if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  kind create cluster --name "${CLUSTER_NAME}" --wait 120s
else
  log "Cluster already exists — reusing"
fi
kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null

# --- 2. Open vSwitch inside the kind node ------------------------------------
# The kind node is an Ubuntu-based container; OVS runs *inside* it so the
# ovs-cni plugin (which talks to /run/openvswitch/db.sock on the node) works.
log "Installing and starting Open vSwitch inside node ${NODE}"
docker exec "${NODE}" bash -eux -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq openvswitch-switch >/dev/null
  # ovs-ctl copes with containers (no systemd); kernel-module load may fail
  # inside Docker Desktop — tolerated because our bridge uses the userspace
  # (netdev) datapath.
  /usr/share/openvswitch/scripts/ovs-ctl start --system-id=random --no-mlockall || true
  ovs-vsctl show
'

log "Creating OVS bridge ${BRIDGE} (userspace datapath) + gateway port"
docker exec "${NODE}" bash -eux -c "
  ovs-vsctl --may-exist add-br ${BRIDGE} -- set bridge ${BRIDGE} datapath_type=netdev
  # Internal port acting as the node-side L3 endpoint on the bridge, so we can
  # ping the VM across the bridge from the node.
  ovs-vsctl --may-exist add-port ${BRIDGE} ovs-gw -- set interface ovs-gw type=internal
  ip addr replace ${GW_IP}/24 dev ovs-gw
  ip link set ovs-gw up
  ovs-vsctl show
"

# --- 3. Multus CNI + OVS CNI via Cluster Network Addons Operator -------------
log "Installing Cluster Network Addons Operator (deploys Multus + ovs-cni)"
CNAO_VERSION="$(curl -fsSL https://api.github.com/repos/kubevirt/cluster-network-addons-operator/releases/latest \
  | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
[[ -n "${CNAO_VERSION}" ]] || die "could not resolve CNAO latest release"
CNAO_URL="https://github.com/kubevirt/cluster-network-addons-operator/releases/download/${CNAO_VERSION}"
kubectl apply -f "${CNAO_URL}/namespace.yaml"
kubectl apply -f "${CNAO_URL}/network-addons-config.crd.yaml"
kubectl apply -f "${CNAO_URL}/operator.yaml"
kubectl -n cluster-network-addons rollout status deployment/cluster-network-addons-operator --timeout=300s

log "Requesting Multus + OVS CNI via NetworkAddonsConfig"
kubectl apply -f - <<'EOF'
apiVersion: networkaddonsoperator.network.kubevirt.io/v1
kind: NetworkAddonsConfig
metadata:
  name: cluster
spec:
  multus: {}
  ovs: {}
  imagePullPolicy: IfNotPresent
EOF
kubectl wait networkaddonsconfig cluster --for condition=Available --timeout=600s

# --- 4. KubeVirt (emulation mode) --------------------------------------------
log "Installing KubeVirt"
KV_VERSION="$(curl -fsSL https://api.github.com/repos/kubevirt/kubevirt/releases/latest \
  | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
[[ -n "${KV_VERSION}" ]] || die "could not resolve KubeVirt latest release"
KV_URL="https://github.com/kubevirt/kubevirt/releases/download/${KV_VERSION}"
kubectl apply -f "${KV_URL}/kubevirt-operator.yaml"
kubectl apply -f "${KV_URL}/kubevirt-cr.yaml"

log "Enabling software emulation (no /dev/kvm in kind on macOS)"
kubectl -n kubevirt patch kubevirt kubevirt --type=merge -p \
  '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
kubectl -n kubevirt wait kubevirt kubevirt --for=jsonpath='{.status.phase}'=Deployed --timeout=600s

# --- 5. Deploy the NAD + VirtualMachine ---------------------------------------
log "Applying manifests.yaml (NetworkAttachmentDefinition + VirtualMachine)"
[[ -f manifests.yaml ]] || die "manifests.yaml not found next to this script"
kubectl apply -f manifests.yaml

log "Waiting for the VirtualMachineInstance to become Ready (TCG boot is slow)"
kubectl wait vm cirros-ovs --for=jsonpath='{.status.printableStatus}'=Running --timeout=600s
kubectl wait vmi cirros-ovs --for=condition=Ready --timeout=600s
log "Giving cloud-init time to configure eth1 (${VM_IP}) inside the guest"
sleep 60

# --- 6. Datapath verification --------------------------------------------------
log "Ping test across ${BRIDGE}: node(${GW_IP}) -> VM(${VM_IP})"
{
  echo "# ping issued from inside kind node '${NODE}', source ${GW_IP} (OVS internal port ovs-gw)"
  echo "# destination ${VM_IP} = eth1 of KubeVirt VMI 'cirros-ovs' attached to ${BRIDGE} via ovs-cni"
  echo "\$ ping -c 10 -I ovs-gw ${VM_IP}"
  docker exec "${NODE}" ping -c 10 -I ovs-gw "${VM_IP}"
} | tee ping_results.txt

log "Dumping OVS flows on ${BRIDGE}"
# OVS >= 3.1 supports --format=json natively; older releases get the text dump
# wrapped into valid JSON so the artifact stays machine-readable either way.
if docker exec "${NODE}" ovs-ofctl dump-flows "${BRIDGE}" --format=json > verification_flows.json 2>/dev/null; then
  log "Native JSON flow dump captured"
else
  log "OVS < 3.1 on node: wrapping text flow dump into JSON"
  docker exec "${NODE}" bash -c "
    ovs-ofctl dump-flows ${BRIDGE} | python3 -c '
import json,sys
lines=[l.strip() for l in sys.stdin if l.strip()]
print(json.dumps({\"bridge\":\"${BRIDGE}\",\"tool\":\"ovs-ofctl dump-flows (text, wrapped)\",\"flows\":lines},indent=2))
'" > verification_flows.json
fi
python3 -m json.tool verification_flows.json >/dev/null && log "verification_flows.json is valid JSON"

log "Interfaces on ${BRIDGE} (for the record):"
docker exec "${NODE}" ovs-vsctl list-ports "${BRIDGE}"

log "DONE — artifacts written: ping_results.txt, verification_flows.json"
log "Teardown with: ./cluster_setup.sh teardown"
