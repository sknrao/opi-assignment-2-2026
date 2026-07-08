#!/usr/bin/env bash
set -Eeuo pipefail

PROFILE="${PROFILE:-kubevirt-ovs-lab}"
MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-docker}"
MEMORY="${MEMORY:-8192}"
CPUS="${CPUS:-4}"
OVS_BRIDGE="${OVS_BRIDGE:-br1}"
OVS_BRIDGE_CIDR="${OVS_BRIDGE_CIDR:-10.10.0.1/24}"
VM_NAMESPACE="${VM_NAMESPACE:-vm-lab}"
VM_NAME="${VM_NAME:-cirros-ovs-vm}"
PING_TARGET="${PING_TARGET:-10.10.0.20}"
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-}"
CNAO_VERSION="${CNAO_VERSION:-v0.102.0}"
APPLY_MANIFESTS="${APPLY_MANIFESTS:-true}"
RUN_VERIFICATION="${RUN_VERIFICATION:-true}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

wait_for_resource() {
  local description="$1"
  shift
  echo "Waiting for ${description}..."
  "$@"
}

require_cmd curl
require_cmd kubectl
require_cmd minikube
require_cmd python3

if ! minikube -p "${PROFILE}" status >/dev/null 2>&1; then
  minikube start \
    -p "${PROFILE}" \
    --driver="${MINIKUBE_DRIVER}" \
    --memory="${MEMORY}" \
    --cpus="${CPUS}" \
    --cni=bridge \
    --container-runtime=containerd
else
  echo "Minikube profile ${PROFILE} already exists; reusing it."
fi

kubectl config use-context "${PROFILE}" >/dev/null
kubectl wait --for=condition=Ready node --all --timeout=5m

minikube -p "${PROFILE}" ssh -- "
set -e
if ! command -v ovs-vsctl >/dev/null 2>&1; then
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openvswitch-switch
fi
sudo service openvswitch-switch start >/dev/null 2>&1 || sudo /usr/share/openvswitch/scripts/ovs-ctl start >/dev/null 2>&1 || true
sudo ovs-vsctl --no-wait init || true
sudo ovs-vsctl --may-exist add-br ${OVS_BRIDGE}
sudo ip addr flush dev ${OVS_BRIDGE} || true
sudo ip addr add ${OVS_BRIDGE_CIDR} dev ${OVS_BRIDGE}
sudo ip link set ${OVS_BRIDGE} up
sudo iptables -C FORWARD -i ${OVS_BRIDGE} -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD 1 -i ${OVS_BRIDGE} -j ACCEPT
sudo iptables -C FORWARD -o ${OVS_BRIDGE} -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD 1 -o ${OVS_BRIDGE} -j ACCEPT
sudo ovs-vsctl show
"

if [[ -z "${KUBEVIRT_VERSION}" ]]; then
  KUBEVIRT_VERSION="$(curl -fsSL https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)"
fi

echo "Installing KubeVirt ${KUBEVIRT_VERSION}..."
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"

for _ in $(seq 1 60); do
  if kubectl -n kubevirt get kubevirt kubevirt >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

kubectl -n kubevirt patch kubevirt kubevirt --type=merge -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}' || true
kubectl -n kubevirt wait kubevirt kubevirt --for=condition=Available --timeout=15m

if ! command -v virtctl >/dev/null 2>&1; then
  ARCH="$(uname -m)"
  case "${ARCH}" in
    x86_64|amd64) VIRTCTL_ARCH="amd64" ;;
    aarch64|arm64) VIRTCTL_ARCH="arm64" ;;
    *) VIRTCTL_ARCH="amd64" ;;
  esac
  curl -fsSL -o /tmp/virtctl "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-${VIRTCTL_ARCH}"
  chmod +x /tmp/virtctl
  sudo mv /tmp/virtctl /usr/local/bin/virtctl
fi

echo "Installing Cluster Network Addons Operator ${CNAO_VERSION} for Multus and OVS CNI..."
kubectl apply -f "https://github.com/kubevirt/cluster-network-addons-operator/releases/download/${CNAO_VERSION}/namespace.yaml"
kubectl apply -f "https://github.com/kubevirt/cluster-network-addons-operator/releases/download/${CNAO_VERSION}/network-addons-config.crd.yaml"
kubectl apply -f "https://github.com/kubevirt/cluster-network-addons-operator/releases/download/${CNAO_VERSION}/operator.yaml"
kubectl -n cluster-network-addons rollout status deployment/cluster-network-addons-operator --timeout=5m

cat <<'EOF_CNAO' | kubectl apply -f -
apiVersion: networkaddonsoperator.network.kubevirt.io/v1
kind: NetworkAddonsConfig
metadata:
  name: cluster
spec:
  multus: {}
  ovs: {}
EOF_CNAO

kubectl wait networkaddonsconfig cluster --for=condition=Available --timeout=15m
kubectl get pods -A | grep -E 'kubevirt|multus|ovs|network-addons' || true

if [[ "${APPLY_MANIFESTS}" == "true" ]]; then
  if [[ ! -f manifests.yaml ]]; then
    echo "ERROR: manifests.yaml not found in current directory. Run this script from the submission directory." >&2
    exit 1
  fi
  kubectl apply -f manifests.yaml
  kubectl -n "${VM_NAMESPACE}" wait pod/ovs-test-pod --for=condition=Ready --timeout=5m || true
  kubectl -n "${VM_NAMESPACE}" wait vmi/"${VM_NAME}" --for=condition=Ready --timeout=15m || true
fi

if [[ "${RUN_VERIFICATION}" == "true" ]]; then
  echo "Generating ping_results.txt..."
  kubectl -n "${VM_NAMESPACE}" exec ovs-test-pod -- ping -c 4 "${PING_TARGET}" > ping_results.txt || true

  echo "Generating verification_flows.json..."
  if minikube -p "${PROFILE}" ssh -- "sudo ovs-ofctl --format=json dump-flows ${OVS_BRIDGE}" > verification_flows.json 2>/tmp/ovs_json_err.txt; then
    true
  else
    minikube -p "${PROFILE}" ssh -- "sudo ovs-ofctl dump-flows ${OVS_BRIDGE}" > /tmp/ovs_flows_raw.txt || true
    python3 - > verification_flows.json <<'PY'
import json
from pathlib import Path
raw = Path('/tmp/ovs_flows_raw.txt').read_text(errors='replace') if Path('/tmp/ovs_flows_raw.txt').exists() else ''
print(json.dumps({
    "bridge": "br1",
    "source_command": "ovs-ofctl dump-flows br1",
    "format_note": "Machine-readable JSON wrapper around raw ovs-ofctl text because ovs-ofctl --format=json is not supported on all OVS builds.",
    "raw_stdout": raw,
    "raw_lines": raw.splitlines()
}, indent=2))
PY
  fi
fi

echo "Done. Expected files: cluster_setup.sh, manifests.yaml, verification_flows.json, ping_results.txt, dpu_offload_concept.md"
