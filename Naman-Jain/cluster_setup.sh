#!/usr/bin/env bash
set -e

echo "Installing required packages"

sudo dnf install -y \
  cri-o \
  cri-tools \
  conntrack \
  curl \
  wget \
  git \
  jq \
  containernetworking-plugins \
  openvswitch \
  qemu-kvm \
  libvirt \
  virt-install

echo "Installing Minikube"

if ! command -v minikube >/dev/null 2>&1; then
  curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
  chmod +x minikube-linux-amd64
  sudo install minikube-linux-amd64 /usr/local/bin/minikube
fi

echo "Installing kubectl"

if ! command -v kubectl >/dev/null 2>&1; then
  curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  chmod +x kubectl
  sudo install kubectl /usr/local/bin/kubectl
fi

echo "Starting CRI-O"

sudo systemctl enable --now crio

echo "Starting Open vSwitch"

sudo systemctl enable --now openvswitch

echo "Starting Minikube"

sudo minikube start \
  --driver=none \
  --container-runtime=cri-o

echo "Installing KubeVirt"

KV_VERSION=$(curl -L -s https://github.com/kubevirt/kubevirt/releases/latest/download/stable.txt)

kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${KV_VERSION}/kubevirt-operator.yaml
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${KV_VERSION}/kubevirt-cr.yaml

kubectl wait kv kubevirt \
  -n kubevirt \
  --for=condition=Available \
  --timeout=10m

echo "Installing CDI"

CDI_VERSION=$(curl -L -s https://github.com/kubevirt/containerized-data-importer/releases/latest/download/release-version.txt)

kubectl apply -f https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml

kubectl apply -f https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml

kubectl wait cdi cdi \
  --for=condition=Available \
  --timeout=10m

echo "Installing Multus"

kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml

kubectl rollout status daemonset/kube-multus-ds \
  -n kube-system \
  --timeout=5m

echo "Installing OVS-CNI"

if [ ! -d ovs-cni ]; then
  git clone https://github.com/k8snetworkplumbingwg/ovs-cni.git
fi

kubectl apply -f ovs-cni/examples/ovs-cni.yml

kubectl rollout status daemonset/ovs-cni-amd64 \
  -n kube-system \
  --timeout=5m

echo "Installing CNI plugins"

sudo mkdir -p /opt/cni/bin
sudo cp -a /usr/libexec/cni/* /opt/cni/bin/

echo "Restarting kubelet"

sudo systemctl restart kubelet

echo "Creating OVS bridge"

sudo ovs-vsctl --may-exist add-br ovs-br0

echo "Deploying manifests"

kubectl apply -f manifests.yaml

echo "Waiting for VM"

kubectl wait vmi cirros-vm \
  --for=jsonpath='{.status.phase}'=Running \
  --timeout=5m || true

echo "Setup completed"
