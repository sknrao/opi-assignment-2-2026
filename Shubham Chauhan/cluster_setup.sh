#!/usr/bin/env bash
#
# cluster_setup.sh
#
# Bootstrap a local KinD cluster for the Cloud-Native OVS Datapath Challenge.
# Installs: KinD, KubeVirt, Multus CNI, OVS CNI, and whereabouts IPAM.
#
# Usage: ./cluster_setup.sh
# Teardown: see the commented TEARDOWN section at the bottom of this file.

set -euo pipefail

# -----------------------------------------------------------------------------
# Version pins
# -----------------------------------------------------------------------------
readonly KUBERNETES_VERSION="v1.30.4"
readonly KUBEVIRT_VERSION="v1.3.1"
readonly MULTUS_VERSION="v4.1.3"
readonly OVS_CNI_VERSION="v0.36.0"
readonly WHEREABOUTS_VERSION="v0.8.0"

# -----------------------------------------------------------------------------
# Cluster settings
# -----------------------------------------------------------------------------
readonly CLUSTER_NAME="ovs-datapath"
readonly OVS_BRIDGE="br-ovs"
readonly NODE_IMAGE="${NODE_IMAGE:-kindest/node:${KUBERNETES_VERSION}}"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
log() {
  echo "[$(date -Iseconds)] $*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

apply_remote_manifest() {
  local url="$1"
  log "Applying manifest ${url}"
  curl -fsSL "${url}" >/dev/null || fail "Manifest URL not reachable: ${url}"
  kubectl apply -f "${url}"
}

# Pins a moving image tag (e.g. 'latest') to a specific release version.
apply_remote_manifest_pinned_image() {
  local url="$1"
  local image="$2"
  local current_tag="$3"
  local target_tag="$4"
  log "Applying ${url} with image '${image}' pinned to ${target_tag}"

  local manifest
  manifest=$(curl -fsSL "${url}")
  if ! grep -q "${image}:${current_tag}" <<<"${manifest}"; then
    fail "Expected image tag '${current_tag}' for '${image}' not found in ${url}; manifest may have changed"
  fi

  sed "s|${image}:${current_tag}|${image}:${target_tag}|g" <<<"${manifest}" | kubectl apply -f -
}

wait_daemonset_ready() {
  local name="$1"
  local ns="${2:-kube-system}"
  local timeout="${3:-300s}"
  log "Waiting for DaemonSet '${name}' in '${ns}' to finish rollout (timeout: ${timeout})..."
  kubectl rollout status daemonset/"${name}" -n "${ns}" --timeout="${timeout}"
}

wait_pods_ready() {
  local ns="$1"
  local timeout="${2:-300s}"
  log "Waiting for all pods in namespace '${ns}' to be Ready (timeout: ${timeout})..."
  kubectl wait --for=condition=Ready pod --all -n "${ns}" --timeout="${timeout}"
}

# -----------------------------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------------------------
check_prerequisites() {
  log "Validating prerequisites..."
  for cmd in docker kubectl kind curl; do
    command_exists "${cmd}" || fail "Required command '${cmd}' not found in PATH"
  done

  # Verify the Docker daemon is reachable before we try to create a cluster.
  docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable"

  log "Prerequisites OK"
}

# -----------------------------------------------------------------------------
# KinD cluster
# -----------------------------------------------------------------------------
create_kind_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    log "KinD cluster '${CLUSTER_NAME}' already exists; skipping creation"
  else
    log "Creating KinD cluster '${CLUSTER_NAME}' with Kubenetes ${KUBERNETES_VERSION}"
    kind create cluster \
      --name "${CLUSTER_NAME}" \
      --image "${NODE_IMAGE}" \
      --wait 120s
  fi

  # Ensure kubectl points at the cluster we just created/validated.
  kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
}

# -----------------------------------------------------------------------------
# KubeVirt
# -----------------------------------------------------------------------------
install_kubevirt() {
  log "Installing KubeVirt ${KUBEVIRT_VERSION}"

  apply_remote_manifest \
    "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"

  if ! kubectl get kubevirt kubevirt -n kubevirt >/dev/null 2>&1; then
    apply_remote_manifest \
      "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"
  else
    log "KubeVirt CR already exists; skipping CR creation"
  fi

  # Fall back to software emulation if KVM is unavailable.
  local kvm_cpu_count
  kvm_cpu_count=$(grep -c -E '(vmx|svm)' /proc/cpuinfo 2>/dev/null || echo 0)
  if [[ ! -e /dev/kvm ]] || [[ "${kvm_cpu_count}" -eq 0 ]]; then
    log "KVM not detected on host; enabling KubeVirt software emulation"
    kubectl patch kubevirt kubevirt -n kubevirt --type=merge \
      --patch '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
  else
    log "KVM detected; leaving hardware virtualization enabled"
  fi

  wait_pods_ready "kubevirt" "600s"

  log "Waiting for KubeVirt CR to reach Deployed phase..."
  kubectl wait --for=jsonpath='{.status.phase}'=Deployed \
    -n kubevirt kubevirt/kubevirt --timeout=600s
}

# -----------------------------------------------------------------------------
# Multus CNI
# -----------------------------------------------------------------------------
install_multus() {
  log "Installing Multus CNI ${MULTUS_VERSION}"

  apply_remote_manifest_pinned_image \
    "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${MULTUS_VERSION}/deployments/multus-daemonset-thick.yml" \
    "ghcr.io/k8snetworkplumbingwg/multus-cni" \
    "snapshot-thick" \
    "${MULTUS_VERSION}-thick"

  wait_daemonset_ready "kube-multus-ds" "kube-system" "300s"
}

# -----------------------------------------------------------------------------
# OVS CNI plugin
# -----------------------------------------------------------------------------
install_ovs_cni() {
  log "Installing OVS CNI ${OVS_CNI_VERSION}"

  apply_remote_manifest_pinned_image \
    "https://raw.githubusercontent.com/k8snetworkplumbingwg/ovs-cni/${OVS_CNI_VERSION}/examples/ovs-cni.yml" \
    "ghcr.io/k8snetworkplumbingwg/ovs-cni-plugin" \
    "latest" \
    "${OVS_CNI_VERSION}"

  # The upstream manifest hardcodes an amd64 node selector; remove it so the
  # multi-arch image runs on arm64 too.
  if kubectl get daemonset ovs-cni-amd64 -n kube-system >/dev/null 2>&1; then
    kubectl patch daemonset ovs-cni-amd64 -n kube-system --type='json' \
      -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector/kubenetes.io~1arch"}]' >/dev/null || true
  fi

  wait_daemonset_ready "ovs-cni-amd64" "kube-system" "300s"
}

# -----------------------------------------------------------------------------
# whereabouts IPAM
# -----------------------------------------------------------------------------
install_whereabouts() {
  log "Installing whereabouts IPAM ${WHEREABOUTS_VERSION}"
  local base
  base="https://raw.githubusercontent.com/k8snetworkplumbingwg/whereabouts/${WHEREABOUTS_VERSION}/doc/crds"

  apply_remote_manifest "${base}/whereabouts.cni.cncf.io_ippools.yaml"
  apply_remote_manifest "${base}/whereabouts.cni.cncf.io_overlappingrangeipreservations.yaml"
  apply_remote_manifest_pinned_image \
    "${base}/daemonset-install.yaml" \
    "ghcr.io/k8snetworkplumbingwg/whereabouts" \
    "latest" \
    "${WHEREABOUTS_VERSION}"

  wait_daemonset_ready "whereabouts" "kube-system" "300s"
}

# -----------------------------------------------------------------------------
# OVS bridge on the KinD node
# -----------------------------------------------------------------------------
setup_ovs_bridge() {
  local node
  node=$(kind get nodes --name "${CLUSTER_NAME}" | head -n1)
  log "Configuring OVS bridge '${OVS_BRIDGE}' on KinD node '${node}'"

  # ovs-cni creates ports but not the bridge itself.
  docker exec "${node}" bash -c '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

    if ! command -v ovs-vsctl >/dev/null 2>&1; then
      echo "Installing openvswitch-switch inside KinD node..."
      apt-get update -qq
      apt-get install -y -qq openvswitch-switch
    fi

    command -v ovs-vsctl >/dev/null 2>&1 || {
      echo "ERROR: ovs-vsctl not found after openvswitch installation"
      exit 1
    }
    command -v ovs-ofctl >/dev/null 2>&1 || {
      echo "ERROR: ovs-ofctl not found after openvswitch installation"
      exit 1
    }

    mkdir -p /run/openvswitch

    if ! modprobe openvswitch 2>/dev/null; then
      echo "WARNING: could not load openvswitch kenel module; host may need it loaded manually"
    fi

    /usr/share/openvswitch/scripts/ovs-ctl start --system-id=random

    ovs-vsctl --may-exist add-br '"${OVS_BRIDGE}"'
    ip link set '"${OVS_BRIDGE}"' mtu 1500 2>/dev/null || true

    # Copy the tuning CNI binary to /opt/cni/bin/ for plugin chains.
    if ! test -x /opt/cni/bin/tuning; then
      apt-get install -y -qq containenetworking-plugins 2>/dev/null || true
      if test -x /usr/lib/cni/tuning; then
        cp /usr/lib/cni/tuning /opt/cni/bin/tuning
        chmod +x /opt/cni/bin/tuning
      fi
    fi
  '

  docker exec "${node}" ovs-vsctl br-exists "${OVS_BRIDGE}" ||
    fail "OVS bridge '${OVS_BRIDGE}' was not created on node '${node}'"

  log "OVS bridge '${OVS_BRIDGE}' is ready on node '${node}'"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  check_prerequisites
  create_kind_cluster
  install_kubevirt
  install_multus
  install_ovs_cni
  install_whereabouts
  setup_ovs_bridge

  local node
  node=$(kind get nodes --name "${CLUSTER_NAME}" | head -n1)

  log "Cluster setup complete."
  log "Cluster context: kind-${CLUSTER_NAME}"
  log "KinD node: ${node}"
  log "OVS bridge: ${OVS_BRIDGE}"
  log "Next steps:"
  log "  1. Apply the workload manifest: kubectl apply -f manifests.yaml"
  log "  2. Inspect the OVS bridge:     docker exec ${node} ovs-vsctl show"
  log "  3. Inspect OVS flows:          docker exec ${node} ovs-ofctl dump-flows ${OVS_BRIDGE}"
}

trap 'fail "cluster_setup.sh failed on line ${LINENO}"' ERR

main "$@"

# -----------------------------------------------------------------------------
# TEARDOWN
# -----------------------------------------------------------------------------
# To reset the environment after reviewing, run:
#
#   kind delete cluster --name ovs-datapath
#
# This removes the KinD node container, the OVS bridge, and all Kubenetes
# state created by this script in one operation.
