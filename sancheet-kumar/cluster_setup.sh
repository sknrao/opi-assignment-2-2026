#!/usr/bin/env bash
set -euo pipefail

echo "Starting Cluster Setup"

# Spin up cluster
echo "[1/6] Spinning up KinD cluster..."
cat <<EOF | kind create cluster --name opi-datapath --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
EOF

# install CNI plugins and VERIFY
echo "[2/6] Injecting standard CNI plugins..."
docker exec opi-datapath-control-plane bash -c "set -euo pipefail && \
    apt-get update && \
    apt-get install -y curl tar && \
    mkdir -p /opt/cni/bin && \
    curl -sSL https://github.com/containernetworking/plugins/releases/download/v1.4.1/cni-plugins-linux-amd64-v1.4.1.tgz | tar -xz -C /opt/cni/bin/ && \
    if [ ! -f /opt/cni/bin/ptp ]; then echo 'CRITICAL ERROR: ptp plugin missing!'; exit 1; else echo 'ptp plugin successfully verified.'; fi"

# OVS
echo "[3/6] Installing Open vSwitch on the KinD node..."
docker exec opi-datapath-control-plane apt-get install -y openvswitch-switch
docker exec opi-datapath-control-plane systemctl enable --now openvswitch-switch
docker exec opi-datapath-control-plane ovs-vsctl add-br br1

# KubeVirt
echo "[4/6] Installing KubeVirt..."
kubectl create -f "https://github.com/kubevirt/kubevirt/releases/download/v1.2.0/kubevirt-operator.yaml"
kubectl create -f "https://github.com/kubevirt/kubevirt/releases/download/v1.2.0/kubevirt-cr.yaml"
kubectl wait --for=condition=Available deployment/virt-operator -n kubevirt --timeout=5m
kubectl -n kubevirt patch kubevirt kubevirt --type=merge --patch '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
kubectl -n kubevirt wait kv kubevirt --for condition=Available --timeout=5m

# Multus
echo "[5/6] Installing Multus CNI..."
kubectl apply -f "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/v4.0.2/deployments/multus-daemonset.yml"
kubectl -n kube-system wait --for=condition=ready -l name=multus pod --timeout=5m

# OVS CNI
echo "[6/6] Installing OVS CNI..."
kubectl apply -f "https://raw.githubusercontent.com/k8snetworkplumbingwg/ovs-cni/master/examples/ovs-cni.yml"

echo "Cluster setup complete"