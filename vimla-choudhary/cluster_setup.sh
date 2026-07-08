#!/usr/bin/env bash

# sets up k3s + ovs + multus + ovs-cni + kubevirt on a single rhel node
# This section details the complete bring-up and validation workflow 
# required to establish VM connectivity through the Open vSwitch datapath.
#
# heads up - this was written and tested on rhel9, so it uses dnf.
# if you're on ubuntu/debian you'll need to swap the openvswitch/git
# install lines for apt instead (something like:
# sudo apt install -y openvswitch-switch git)
# rest of it (k3s, multus, ovs-cni, kubevirt, the cni path fixes) isn't
# rhel-specific and should just work the same either way

set -euo pipefail

# The workflow is intentionally broken into discrete steps so that any failure can be traced to its exact stage of execution.
CURRENT_STEP="starting up"
on_error() {
  echo
  echo "!! failed during: ${CURRENT_STEP}"
  echo "!! re-run the script - most steps are safe to redo (br0/git clone/cni copies"
  echo "!! all check for existing state first), you'll just skip past what's already done"
}
trap on_error ERR

# quick check before doing anything else 
for tool in dnf curl sudo; do
  if ! command -v "${tool}" &>/dev/null; then
    echo "missing required tool: ${tool} - install it and re-run"
    exit 1
  fi
done

CURRENT_STEP="step 1: installing openvswitch"
echo "step 1: installing openvswitch"
if command -v ovs-vsctl &>/dev/null; then
  echo "  ovs-vsctl already on PATH, skipping install"
else
  # plain "openvswitch" package didn't actually resolve on this box,
  # had to use the versioned one. leaving both in just in case
  sudo dnf install -y openvswitch || true
  sudo dnf install -y openvswitch3.4
fi
sudo systemctl enable --now openvswitch || true
sudo ovs-vsctl show

CURRENT_STEP="step 2: creating br0"
echo "step 2: creating br0"
sudo ovs-vsctl --may-exist add-br br0
sudo ovs-vsctl show

CURRENT_STEP="step 3: installing k3s"
echo "step 3: installing k3s"
if command -v k3s &>/dev/null; then
  echo "  k3s already installed, skipping install (still fine to keep going)"
else
  curl -sfL https://get.k3s.io | sh -
fi
sudo systemctl status k3s --no-pager
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
export KUBECONFIG=~/.kube/config
kubectl get nodes

CURRENT_STEP="step 4: installing multus (thick daemonset)"
echo "step 4: installing multus (thick daemonset)"
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml

CURRENT_STEP="step 5: installing ovs-cni"
echo "step 5: installing ovs-cni"
# applying the yml straight from the raw github url didn't work right for me,
# cloning the repo locally and applying from there did
sudo dnf install -y git
if [ ! -d /tmp/ovs-cni ]; then
  git clone https://github.com/k8snetworkplumbingwg/ovs-cni.git /tmp/ovs-cni
fi
kubectl apply -f /tmp/ovs-cni/examples/ovs-cni.yml

CURRENT_STEP="step 6: k3s cni binary fix"
echo "step 6: k3s cni binary fix"
# k3s's containerd looks in /var/lib/rancher/k3s/data/cni for cni binaries,
# not /opt/cni/bin like everything else assumes. copying both directions
# so nothing goes missing. spent way too long debugging this via journalctl
sudo cp /opt/cni/bin/multus-shim         /var/lib/rancher/k3s/data/cni/ 2>/dev/null || true
sudo cp /opt/cni/bin/ovs                 /var/lib/rancher/k3s/data/cni/ 2>/dev/null || true
sudo cp /opt/cni/bin/ovs-mirror-consumer /var/lib/rancher/k3s/data/cni/ 2>/dev/null || true
sudo cp /opt/cni/bin/ovs-mirror-producer /var/lib/rancher/k3s/data/cni/ 2>/dev/null || true
sudo ls -la /var/lib/rancher/k3s/data/cni/

# and the other direction - k3s ships its own copies of the standard
# plugins as symlinks, need those actually copied into /opt/cni/bin too
for plugin in bandwidth bridge firewall flannel host-local loopback portmap; do
  sudo cp -L "/var/lib/rancher/k3s/data/cni/${plugin}" "/opt/cni/bin/${plugin}"
  sudo chmod +x "/opt/cni/bin/${plugin}"
done

CURRENT_STEP="step 7: patching multus daemonset hostpath"
echo "step 7: patching multus daemonset hostpath"
# multus defaults to mounting /etc/cni/net.d but k3s keeps its cni config
# somewhere else entirely, so multus never actually sees it unless patched
kubectl -n kube-system patch daemonset kube-multus-ds --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/volumes/0/hostPath/path", "value": "/var/lib/rancher/k3s/agent/etc/cni/net.d"}
]'
sudo ls -la /var/lib/rancher/k3s/agent/etc/cni/net.d/

CURRENT_STEP="step 8: restarting k3s so it picks everything up"
echo "step 8: restarting k3s so it picks everything up"
sudo systemctl restart k3s
sleep 10
sudo systemctl status k3s --no-pager

CURRENT_STEP="step 9: installing kubevirt"
echo "step 9: installing kubevirt"
export KV_VERSION=$(curl -s https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KV_VERSION}/kubevirt-operator.yaml"
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KV_VERSION}/kubevirt-cr.yaml"
kubectl -n kubevirt wait kv kubevirt --for condition=Available --timeout=5m

CURRENT_STEP="step 10: installing virtctl"
echo "step 10: installing virtctl"
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -L -o /tmp/virtctl "https://github.com/kubevirt/kubevirt/releases/download/${KV_VERSION}/virtctl-${KV_VERSION}-linux-${ARCH}"
chmod +x /tmp/virtctl
sudo mv /tmp/virtctl /usr/local/bin/virtctl
virtctl version

echo
echo "done. now run: kubectl apply -f manifests.yaml"