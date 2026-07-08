#!/usr/bin/env bash
#
# cluster_setup.sh
#
# Bootstraps: KinD cluster -> Multus CNI -> Open vSwitch (inside the KinD
# node container, userspace/netdev datapath) -> OVS CNI -> KubeVirt
# (software emulation, since no /dev/kvm is passed into the KinD node).
#
# This reflects the actual working sequence used in a GitHub Codespaces
# environment, including the fixes needed along the way:
#   - OVS must be installed/run INSIDE the KinD node container, not the
#     Codespaces host, because hostPath volumes in Kubernetes pods resolve
#     against the node's filesystem.
#   - No kernel module (openvswitch.ko) is available inside containers, so
#     OVS runs its userspace/netdev datapath instead of the kernel datapath.
#   - ovsdb-server needs its database created manually via `ovsdb-tool
#     create` the first time, since Debian's postinst script is blocked by
#     policy-rc.d inside the node container.
#   - ovs-cni.yml is templated (`ovs-cni.yml.in`) and must be rendered with
#     `envsubst`, including CNI_MOUNT_PATH and
#     OVS_CNI_MARKER_HEALTHCHECK_INTERVAL, which are easy to miss.
#
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ovs-lab}"
OVS_BRIDGE="${OVS_BRIDGE:-br-ovs-lab}"
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-}"
MULTUS_MANIFEST_URL="https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml"
OVS_CNI_REPO="https://github.com/k8snetworkplumbingwg/ovs-cni.git"

log() { echo -e "\033[1;32m[cluster_setup]\033[0m $*"; }

# ---------------------------------------------------------------------------
# 1. KinD cluster
# ---------------------------------------------------------------------------
log "Creating KinD cluster '${CLUSTER_NAME}'..."
if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  kind create cluster --name "${CLUSTER_NAME}"
else
  log "Cluster ${CLUSTER_NAME} already exists, reusing it"
fi
kubectl cluster-info --context "kind-${CLUSTER_NAME}"

# ---------------------------------------------------------------------------
# 2. Multus CNI
# ---------------------------------------------------------------------------
log "Installing Multus CNI..."
kubectl apply -f "${MULTUS_MANIFEST_URL}"
kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout=180s

# ---------------------------------------------------------------------------
# 3. Open vSwitch INSIDE the KinD node container
# ---------------------------------------------------------------------------
NODE="${CLUSTER_NAME}-control-plane"
log "Installing Open vSwitch inside node container '${NODE}'..."
docker exec "${NODE}" bash -c "apt-get update && apt-get install -y openvswitch-switch"

log "Initializing OVS database (postinst service auto-start is blocked in containers)..."
docker exec "${NODE}" bash -c "mkdir -p /etc/openvswitch && \
  test -f /etc/openvswitch/conf.db || \
  ovsdb-tool create /etc/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema"

log "Starting ovsdb-server and ovs-vswitchd (userspace/netdev datapath)..."
docker exec "${NODE}" bash -c "pgrep ovsdb-server || \
  ovsdb-server --remote=punix:/var/run/openvswitch/db.sock \
    --remote=db:Open_vSwitch,Open_vSwitch,manager_options \
    --pidfile --detach --log-file"
docker exec "${NODE}" bash -c "pgrep ovs-vswitchd || \
  ovs-vswitchd --pidfile --detach --log-file -vconsole:off"

log "Creating OVS bridge '${OVS_BRIDGE}' (netdev datapath, no kernel module needed)..."
docker exec "${NODE}" bash -c \
  "ovs-vsctl --may-exist add-br ${OVS_BRIDGE} -- set bridge ${OVS_BRIDGE} datapath_type=netdev"
docker exec "${NODE}" ovs-vsctl show

# ---------------------------------------------------------------------------
# 4. OVS CNI plugin (templated manifest, needs envsubst)
# ---------------------------------------------------------------------------
log "Rendering and installing OVS CNI..."
if [ ! -d /tmp/ovs-cni ]; then
  git clone --depth 1 "${OVS_CNI_REPO}" /tmp/ovs-cni
fi

export NAMESPACE=kube-system
export CNI_MOUNT_PATH=/opt/cni/bin
export OVS_CNI_MARKER_HEALTHCHECK_INTERVAL=60

envsubst < /tmp/ovs-cni/manifests/ovs-cni.yml.in > /tmp/ovs-cni/manifests/ovs-cni.yml
kubectl apply -f /tmp/ovs-cni/manifests/ovs-cni.yml
kubectl -n kube-system rollout status daemonset/ovs-cni-amd64 --timeout=180s

# ---------------------------------------------------------------------------
# 5. KubeVirt (software emulation - no /dev/kvm passed into the KinD node)
# ---------------------------------------------------------------------------
if [ -z "${KUBEVIRT_VERSION}" ]; then
  KUBEVIRT_VERSION=$(curl -sL https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)
fi
log "Installing KubeVirt ${KUBEVIRT_VERSION}..."
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"

log "Enabling software emulation (no /dev/kvm inside the KinD node)..."
kubectl -n kubevirt wait kv kubevirt --for condition=Available --timeout=400s || true
kubectl -n kubevirt patch kubevirt kubevirt --type=merge \
  --patch '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
kubectl -n kubevirt wait kv kubevirt --for condition=Available --timeout=400s

# ---------------------------------------------------------------------------
# 6. virtctl
# ---------------------------------------------------------------------------
log "Installing virtctl..."
VIRTCTL_VERSION=$(kubectl get kubevirt.kubevirt.io/kubevirt -n kubevirt -o=jsonpath="{.status.observedKubeVirtVersion}")
curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VIRTCTL_VERSION}/virtctl-${VIRTCTL_VERSION}-linux-amd64"
chmod +x virtctl
sudo mv virtctl /usr/local/bin/virtctl

log "Cluster bootstrap complete. Next: kubectl apply -f manifests.yaml"
