#!/usr/bin/env bash
#
# cluster_setup.sh - bootstrap a local Kubernetes cluster that runs a CirrOS VM
# (via KubeVirt) attached to an Open vSwitch bridge through Multus + OVS-CNI, then
# ping across the OVS datapath and dump the resulting flows.
#
# Target environment: a Linux host with Docker and /dev/kvm (or KubeVirt software
# emulation, which this script enables). It is NOT expected to run on macOS, which
# has no KVM and no OVS kernel datapath - see NOTES.md for why the capture files in
# this submission are representative rather than captured here.
#
# The script is idempotent enough to re-run: it recreates the kind cluster from
# scratch each time. Run it from the folder that contains manifests.yaml.
#
# Usage:
#   ./cluster_setup.sh            # full bootstrap + verification
#   CLEANUP=1 ./cluster_setup.sh  # delete the cluster and exit
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-ovs-dpu}"
OVS_BRIDGE="${OVS_BRIDGE:-br1}"
NODE="${CLUSTER_NAME}-control-plane"     # kind names the single node like this
MANIFESTS="${MANIFESTS:-manifests.yaml}"
MULTUS_URL="https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml"
OVS_CNI_URL="https://raw.githubusercontent.com/k8snetworkplumbingwg/ovs-cni/main/examples/ovs-cni.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# 0. Preconditions / optional cleanup
# ----------------------------------------------------------------------------
for bin in docker kind kubectl; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' is required but not installed."
done
docker info >/dev/null 2>&1 || die "Docker daemon is not reachable."

if [[ "${CLEANUP:-0}" == "1" ]]; then
  log "Deleting kind cluster '${CLUSTER_NAME}'"
  kind delete cluster --name "${CLUSTER_NAME}" || true
  exit 0
fi

# ----------------------------------------------------------------------------
# 1. Cluster setup - lightweight local Kubernetes via kind
# ----------------------------------------------------------------------------
log "Creating kind cluster '${CLUSTER_NAME}'"
kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF
kubectl config use-context "kind-${CLUSTER_NAME}"
# single-node cluster: let workloads schedule on the control-plane node
kubectl taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true

# ----------------------------------------------------------------------------
# 2. Open vSwitch on the node
#    OVS-CNI ships only the CNI binary; the OVS daemon and the target bridge must
#    already exist on the node. kind nodes are Debian-based, so install it there.
# ----------------------------------------------------------------------------
log "Installing and starting Open vSwitch inside node '${NODE}'"
docker exec "${NODE}" bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq openvswitch-switch >/dev/null
  # kind runs systemd; fall back to launching the daemons directly if needed
  (systemctl start openvswitch-switch 2>/dev/null) || \
    (/usr/share/openvswitch/scripts/ovs-ctl start --system-id=random)
'
log "Creating OVS bridge '${OVS_BRIDGE}' on the node"
docker exec "${NODE}" bash -c "ovs-vsctl --may-exist add-br ${OVS_BRIDGE} && ovs-vsctl set bridge ${OVS_BRIDGE} fail-mode=standalone"
docker exec "${NODE}" ovs-vsctl show

# ----------------------------------------------------------------------------
# 3. Networking stack - Multus + OVS-CNI
# ----------------------------------------------------------------------------
log "Installing Multus CNI"
kubectl apply -f "${MULTUS_URL}"
kubectl -n kube-system rollout status ds/kube-multus-ds --timeout=180s

log "Installing OVS-CNI (plugin + marker)"
kubectl apply -f "${OVS_CNI_URL}"
kubectl -n kube-system rollout status ds/ovs-cni-amd64 --timeout=180s

# ----------------------------------------------------------------------------
# 4. KubeVirt - operator + CR, with software emulation (no /dev/kvm required)
# ----------------------------------------------------------------------------
log "Installing KubeVirt operator + CR"
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-$(curl -fsSL https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)}"
echo "KubeVirt version: ${KUBEVIRT_VERSION}"
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"

log "Enabling software emulation (host has no KVM)"
kubectl -n kubevirt patch kubevirt kubevirt --type=merge \
  -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'

log "Waiting for KubeVirt to become Available (this can take several minutes)"
kubectl -n kubevirt wait kv kubevirt --for=condition=Available --timeout=600s

# virtctl is handy for consoles; install it if missing
if ! command -v virtctl >/dev/null 2>&1; then
  log "Installing virtctl"
  curl -fsSL -o /tmp/virtctl \
    "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64"
  chmod +x /tmp/virtctl && sudo mv /tmp/virtctl /usr/local/bin/virtctl || VIRTCTL=/tmp/virtctl
fi
VIRTCTL="${VIRTCTL:-virtctl}"

# ----------------------------------------------------------------------------
# 5. VM deployment - NADs + two CirrOS VMs on the OVS secondary network
# ----------------------------------------------------------------------------
log "Applying manifests (NetworkAttachmentDefinition + VirtualMachines)"
kubectl apply -f "${SCRIPT_DIR}/${MANIFESTS}"

log "Waiting for both VMs to reach Running"
kubectl wait vmi/cirros-vm1 --for=condition=Ready --timeout=600s
kubectl wait vmi/cirros-vm2 --for=condition=Ready --timeout=600s

# ----------------------------------------------------------------------------
# 6. Datapath verification - ping across the OVS bridge, then dump flows
# ----------------------------------------------------------------------------
# Log into vm1 over the serial console and ping vm2's OVS-network address. The
# expect-style helper drives the CirrOS console (login cirros/gocubsgohost).
log "Running ping test vm1 -> vm2 (10.10.0.2) over the OVS network"
PING_CMD='ping -c 4 10.10.0.2'
{
  echo "# ping ${PING_CMD} from cirros-vm1 (10.10.0.1) to cirros-vm2 (10.10.0.2)"
  echo "# captured $(date -u +%Y-%m-%dT%H:%M:%SZ) via 'virtctl console cirros-vm1'"
  "${VIRTCTL}" console cirros-vm1 <<CONSOLE || true
cirros
gocubsgohost
${PING_CMD}
CONSOLE
} | tee "${SCRIPT_DIR}/ping_results.txt"

log "Dumping OVS flows on '${OVS_BRIDGE}' as JSON -> verification_flows.json"
# ovs-ofctl prints text; convert each flow line into a JSON object for machine use.
docker exec "${NODE}" ovs-ofctl dump-flows "${OVS_BRIDGE}" \
  | awk 'BEGIN{print "{\"bridge\":\"'"${OVS_BRIDGE}"'\",\"flows\":["; sep=""}
         /cookie=/{gsub(/^[ \t]+/,""); printf "%s{\"raw\":\"%s\"}", sep, $0; sep=",\n"}
         END{print "]}"}' \
  > "${SCRIPT_DIR}/verification_flows.json"
docker exec "${NODE}" ovs-vsctl list-ports "${OVS_BRIDGE}" || true

log "Done. Deliverable captures written next to this script:"
echo "  - ${SCRIPT_DIR}/ping_results.txt"
echo "  - ${SCRIPT_DIR}/verification_flows.json"
echo "Tear down with: CLEANUP=1 ./cluster_setup.sh"
