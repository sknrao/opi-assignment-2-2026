#!/bin/bash

# cluster_setup.sh
# Automates the creation of a Kind cluster and installs KubeVirt, Multus, and OVS components.

set -e
echo "Starting Environment Setup for OVS Datapath Challenge..."

# 1. Create Kind Cluster
echo "[Phase 2] Creating Kind Cluster..."
kind create cluster --name ovs-lab --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
EOF

# 2. Install KubeVirt
echo "[Phase 3] Installing KubeVirt..."
export KUBEVIRT_VERSION=$(curl -s https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)
kubectl create -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml
kubectl create -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml

echo "Waiting for KubeVirt to become ready..."
kubectl wait -n kubevirt kv kubevirt --for condition=Available --timeout=300s

# Enable software emulation just in case KVM/nested virtualization isn't fully available in WSL
kubectl patch kubevirt kubevirt -n kubevirt --type=merge --patch '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'

# 3. Install Multus CNI
echo "[Phase 4] Installing Multus CNI..."
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml
echo "Waiting for Multus pods..."
kubectl rollout status daemonset/kube-multus-ds -n kube-system --timeout=120s

# 4. Install Open vSwitch on Kind Node
echo "[Phase 5] Installing Open vSwitch on Kind Node..."
docker exec ovs-lab-control-plane apt-get update
docker exec ovs-lab-control-plane apt-get install -y openvswitch-switch
docker exec ovs-lab-control-plane systemctl start openvswitch-switch
docker exec ovs-lab-control-plane ovs-vsctl add-br br0

# 5. Install OVS CNI
echo "[Phase 6] Installing OVS CNI Plugin..."
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/ovs-cni/master/examples/ovs-cni.yml

echo "Waiting for OVS CNI daemonset..."
kubectl rollout status daemonset/ovs-cni-amd64 -n kube-system --timeout=120s || true
# Note: The Daemonset name might differ depending on architecture (ovs-cni-amd64 or just ovs-cni-marker)

echo "======================================"
echo "Cluster setup complete!"
echo "Next: Apply manifests.yaml and test VM networking."
echo "======================================"
