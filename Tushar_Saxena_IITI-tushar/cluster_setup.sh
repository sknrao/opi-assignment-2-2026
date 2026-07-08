#!/usr/bin/env bash
#
# cluster_setup.sh
# End-to-end bootstrap for the Assignment 2 lab: Kind + KubeVirt (emulated) + CDI +
# Multus + Open vSwitch + OVS-CNI, with an OVS-attached CirrOS VM.
#
# This script mirrors the exact command sequence that was run and verified
# interactively on 2026-07-08 (see opi_assignment_2_commands.txt for the raw
# session log). It is written to be re-runnable end to end.
#
# Requirements: Docker, kind, kubectl, virtctl, curl, git.
set -euo pipefail

CLUSTER_NAME="ovs-lab"
NODE_NAME="${CLUSTER_NAME}-control-plane"

echo "==> [1/8] Creating Kind cluster: ${CLUSTER_NAME}"
cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
EOF

kubectl wait --for=condition=Ready "node/${NODE_NAME}" --timeout=180s
kubectl get nodes

echo "==> [2/8] Installing KubeVirt"
KV_VER=$(curl -s https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)
echo "KubeVirt version: ${KV_VER}"
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KV_VER}/kubevirt-operator.yaml"
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KV_VER}/kubevirt-cr.yaml"
kubectl wait -n kubevirt kv kubevirt --for=condition=Available --timeout=300s

echo "==> [3/8] Enabling emulation"
# Kind nodes run as containers and do not expose /dev/kvm from the host, so
# KubeVirt must run its virt-launcher pods in software emulation (QEMU/TCG)
# rather than hardware-accelerated KVM.
kubectl patch kubevirt kubevirt -n kubevirt --type merge -p '
spec:
  configuration:
    developerConfiguration:
      useEmulation: true
'

echo "==> [4/8] Installing CDI (Containerized Data Importer)"
CDI_VER="v1.65.0"
kubectl apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VER}/cdi-operator.yaml"
kubectl apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VER}/cdi-cr.yaml"
kubectl wait cdi cdi -n cdi --for=condition=Available --timeout=300s

echo "==> [5/8] Installing Multus"
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml
kubectl rollout status daemonset/kube-multus-ds -n kube-system --timeout=300s

echo "==> [6/8] Installing Open vSwitch inside the Kind node"
docker exec "${NODE_NAME}" apt-get update
docker exec "${NODE_NAME}" apt-get install -y openvswitch-switch

echo "==> [7/8] Starting OVS and creating br0"
docker exec "${NODE_NAME}" /usr/share/openvswitch/scripts/ovs-ctl start
docker exec "${NODE_NAME}" ovs-vsctl add-br br0
docker exec "${NODE_NAME}" ip link set br0 up
docker exec "${NODE_NAME}" ovs-vsctl show

echo "==> [8/8] Installing OVS-CNI"
# The published raw.githubusercontent.com manifest 404'd, so OVS-CNI is
# installed from a clone of the upstream repo instead.
if [ ! -d ovs-cni ]; then
  git clone https://github.com/k8snetworkplumbingwg/ovs-cni.git
fi
kubectl apply -f ovs-cni/examples/ovs-cni.yml
kubectl rollout status daemonset/ovs-cni-amd64 -n kube-system --timeout=300s

echo "==> Applying manifests (NetworkAttachmentDefinition + VirtualMachine)"
kubectl apply -f manifests.yaml

echo "==> Done. Verify with:"
echo "    kubectl get vm,vmi -o wide"
echo "    docker exec ${NODE_NAME} ovs-vsctl show"
echo "    docker exec ${NODE_NAME} ovs-ofctl dump-flows br0"
