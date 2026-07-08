#!/bin/bash
set -e

CLUSTER_NAME="dpu-test"
NODE_NAME="${CLUSTER_NAME}-control-plane"

echo "======================================="
echo "1. Spinning up the KinD Cluster"
echo "======================================="
kind create cluster --name $CLUSTER_NAME

echo "======================================="
echo "2. Installing Open vSwitch inside Node"
echo "======================================="
docker exec $NODE_NAME apt-get update
docker exec $NODE_NAME apt-get install -y openvswitch-switch
docker exec $NODE_NAME systemctl enable --now openvswitch-switch
docker exec $NODE_NAME ovs-vsctl add-br br-int
docker exec $NODE_NAME ovs-vsctl show

echo "======================================="
echo "3. Installing Multus & OVS CNI"
echo "======================================="
# 1. Apply Multus
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml

# Check for the correct DaemonSet name (kube-multus-ds)
echo "Waiting for Multus to spin up..."
kubectl rollout status daemonset kube-multus-ds -n kube-system --timeout=60s

# 2. Compile and install the OVS-CNI plugin inside the node
echo "Installing OVS CNI plugin..."
docker exec $NODE_NAME apt-get install -y golang-go git
docker exec $NODE_NAME git clone https://github.com/k8snetworkplumbingwg/ovs-cni.git /tmp/ovs-cni
docker exec $NODE_NAME bash -c "cd /tmp/ovs-cni && go build -o ovs cmd/plugin/plugin.go && mv ovs /opt/cni/bin/ovs"

echo "======================================="
echo "4. Installing KubeVirt (Virtualization Engine)"
echo "======================================="
KV_VERSION=$(curl -s https://api.github.com/repos/kubevirt/kubevirt/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
echo "Deploying KubeVirt ${KV_VERSION}..."

kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KV_VERSION}/kubevirt-operator.yaml"

echo "Applying Software Emulation Fix for nested virtualization..."
kubectl create namespace kubevirt || true
kubectl create configmap -n kubevirt kubevirt-config --from-literal debug.useEmulation=true --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KV_VERSION}/kubevirt-cr.yaml"

echo "Waiting for KubeVirt to become ready (this may take 1-2 minutes)..."
kubectl wait -n kubevirt kv kubevirt --for condition=Available --timeout=180s

echo "======================================="
echo "Initialization Complete!"
echo "======================================="
kubectl get pods -A

