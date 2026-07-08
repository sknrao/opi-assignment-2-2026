#!/bin/bash
set -e

CLUSTER_NAME="OVS-lab"
LAB_NAMESPACE="test-lab"
OVS_BRIDGE="SW-bridge"
OVS_NETWORK="vm-ovs-network"
KV_VERSION="v1.8.4"
CDI_VERSION="v1.65.0"
KIND_IMAGE="kindest/node:v1.36.1"
KV_RELEASE="https://github.com/kubevirt/kubevirt/releases/download/${KV_VERSION}"
CDI_RELEASE="https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}"
MULTUS_URL="https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml"
OVS_CNI_URL="https://raw.githubusercontent.com/k8snetworkplumbingwg/ovs-cni/main/examples/ovs-cni.yml"

# Install prerequisites
echo "Checking required tools"
for tool in docker kubectl kind curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then echo "Error: $tool is not installed."; exit 1; fi
done

# Create KinD cluster
echo "Creating Kind cluster: '${CLUSTER_NAME}'"
kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_IMAGE}"
echo "Waiting for node to become Ready"
kubectl wait --for=condition=Ready node --all --timeout=60s

# Install KubeVirt
echo "Installing KubeVirt ${KV_VERSION}"
kubectl apply -f "${KV_RELEASE}/kubevirt-operator.yaml"
kubectl wait -n kubevirt deployment/virt-operator --for=condition=Available --timeout=300s
kubectl apply -f "${KV_RELEASE}/kubevirt-cr.yaml"
echo "Waiting for KubeVirt CR"
kubectl wait -n kubevirt kubevirt/kubevirt --for=jsonpath='{.status.phase}'=Deployed --timeout=300s
for deploy in virt-api virt-controller; do
    kubectl rollout status deployment/${deploy} -n kubevirt --timeout=60s
done

# Install CDI
echo "Installing CDI ${CDI_VERSION}"
kubectl apply -f "${CDI_RELEASE}/cdi-operator.yaml"
kubectl wait -n cdi deployment/cdi-operator --for=condition=Available --timeout=300s
kubectl apply -f "${CDI_RELEASE}/cdi-cr.yaml"
echo "Waiting for CDI CR"
kubectl wait -n cdi cdi/cdi --for=jsonpath='{.status.phase}'=Deployed --timeout=300s
kubectl rollout status deployment/cdi-apiserver -n cdi --timeout=60s

echo "Installing Multus & OVS CNI"
kubectl apply -f "${MULTUS_URL}" -f "${OVS_CNI_URL}"
for ds in kube-multus-ds ovs-cni-amd64; do
    kubectl rollout status daemonset/${ds} -n kube-system --timeout=60s
done
#------------------------------------------------------------------------------
# Install and bootstrap Open vSwitch on each KinD node.
# KinD nodes do not include a configured Open vSwitch instance by default.
# This block installs the required OVS packages, initializes the OVS database,
# starts the OVS services if they are not already running, and creates the
#------------------------------------------------------------------------------
echo "Installing & Bootstrapping OVS in nodes"
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    docker exec "${node}" sh -c "apt-get update -qq && apt-get install -y -qq openvswitch-common openvswitch-switch"
    
    docker exec "${node}" bash -c "
        mkdir -p /var/lib/openvswitch /var/run/openvswitch /var/log/openvswitch
        [ ! -f /var/lib/openvswitch/conf.db ] && ovsdb-tool create /var/lib/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema
        pgrep -x ovsdb-server >/dev/null || ovsdb-server --remote=punix:/var/run/openvswitch/db.sock --remote=db:Open_vSwitch,Open_vSwitch,manager_options --pidfile=/var/run/openvswitch/ovsdb-server.pid --detach --log-file=/var/log/openvswitch/ovsdb-server.log /var/lib/openvswitch/conf.db
        ovs-vsctl --no-wait init
        pgrep -x ovs-vswitchd >/dev/null || ovs-vswitchd --pidfile=/var/run/openvswitch/ovs-vswitchd.pid --detach --log-file=/var/log/openvswitch/ovs-vswitchd.log
        ovs-vsctl br-exists ${OVS_BRIDGE} || ovs-vsctl add-br ${OVS_BRIDGE}
    "
done

# Deploy networking components
echo "Creating namespace and NetworkAttachmentDefinition"
kubectl create namespace "${LAB_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
cat <<EOF | kubectl apply -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${OVS_NETWORK}
  namespace: ${LAB_NAMESPACE}
spec:
  config: '{"cniVersion": "0.3.1", "name": "${OVS_NETWORK}", "type": "ovs", "bridge": "${OVS_BRIDGE}"}'
EOF

echo -e "\n Cluster Summary:\n"
for cmd in "kubectl get nodes" "kubectl get kubevirt -n kubevirt" "kubectl get cdi -n cdi" "kubectl get network-attachment-definitions -n ${LAB_NAMESPACE}"; do
    echo -e "\n[$cmd]" && $cmd
done
echo -e "\n[Open vSwitch]"
docker exec "${CLUSTER_NAME}-control-plane" ovs-vsctl show
echo -e "\nCluster setup done"