#!/bin/bash
# =============================================================================
# PRODUCTION-GRADE KUBERNETES + KUBEVIRT + OVS CLUSTER SETUP
# Enhanced with best practices from multiple implementations
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# --------------------------------------------------------------------------
# Configuration (all overridable via environment variables)
# --------------------------------------------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-kubevirt-ovs-cluster}"
CLUSTER_TYPE="${CLUSTER_TYPE:-kind}"  # kind or k3s
KIND_VERSION="${KIND_VERSION:-v0.27.0}"
KIND_NODE_TAG="${KIND_NODE_TAG:-v1.32.2}"
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.3.0}"
MULTUS_VERSION="${MULTUS_VERSION:-v4.2.2}"
OVS_CNI_VERSION="${OVS_CNI_VERSION:-v0.38.0}"
OVS_BRIDGE_NAME="${OVS_BRIDGE_NAME:-ovs-br0}"
OVS_VLAN="${OVS_VLAN:-100}"
OVS_HOST_IP="${OVS_HOST_IP:-192.168.100.1}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/output}"
TIMEOUT_SHORT="${TIMEOUT_SHORT:-120s}"
TIMEOUT_MED="${TIMEOUT_MED:-300s}"
TIMEOUT_LONG="${TIMEOUT_LONG:-600s}"
KUBECONFIG_PATH="${HOME}/.kube/config"

# --------------------------------------------------------------------------
# Logging helpers
# --------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN ]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}==> $*${NC}"; }

# --------------------------------------------------------------------------
# Cleanup / error trap
# --------------------------------------------------------------------------
TMP_FILES=()
cleanup() {
  local code=$?
  for f in "${TMP_FILES[@]:-}"; do [[ -n "$f" ]] && rm -f "$f"; done
  if [[ $code -ne 0 ]]; then
    err "Script exited with code ${code}."
    warn "Cluster '${CLUSTER_NAME}' (if created) was left running for inspection."
    if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
      warn "Inspect: kubectl get pods -A ; kind export logs --name ${CLUSTER_NAME} /tmp/kind-logs"
      warn "Tear down: kind delete cluster --name ${CLUSTER_NAME}"
    else
      warn "Tear down k3s: sudo systemctl stop k3s && sudo /usr/local/bin/k3s-uninstall.sh"
    fi
  fi
}
trap cleanup EXIT

# retry function
retry() {
  local n="$1" sleep_s="$2" desc="$3"; shift 3
  [[ "$1" == "--" ]] && shift
  local i
  for ((i=1; i<=n; i++)); do
    if "$@"; then return 0; fi
    warn "  ${desc}: attempt ${i}/${n} failed, retrying in ${sleep_s}s..."
    sleep "${sleep_s}"
  done
  err "${desc}: all ${n} attempts failed."
  return 1
}

# --------------------------------------------------------------------------
# Help text
# --------------------------------------------------------------------------
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<EOF
cluster_setup.sh — Production-grade Kubernetes + KubeVirt + OVS cluster setup

USAGE:
  ./cluster_setup.sh [OPTIONS]

OPTIONS:
  --help, -h           Show this help message
  --cleanup            Tear down existing cluster and exit

ENVIRONMENT VARIABLES:
  CLUSTER_NAME=${CLUSTER_NAME}
  CLUSTER_TYPE=${CLUSTER_TYPE}  (kind or k3s)
  KIND_VERSION=${KIND_VERSION}
  KUBEVIRT_VERSION=${KUBEVIRT_VERSION}
  MULTUS_VERSION=${MULTUS_VERSION}
  OVS_BRIDGE_NAME=${OVS_BRIDGE_NAME}
  OVS_VLAN=${OVS_VLAN}
  OUTPUT_DIR=${OUTPUT_DIR}

EXAMPLES:
  # Use KinD cluster (default)
  ./cluster_setup.sh

  # Use k3s instead
  CLUSTER_TYPE=k3s ./cluster_setup.sh

  # Custom OVS bridge name
  OVS_BRIDGE_NAME=br1 ./cluster_setup.sh

  # Cleanup
  ./cluster_setup.sh --cleanup

EXIT CODES:
  0 = success with verified datapath
  1 = bootstrap/installation failed
  2 = cluster created but verification failed
EOF
  exit 0
fi

# --------------------------------------------------------------------------
# Cleanup mode
# --------------------------------------------------------------------------
if [[ "${1:-}" == "--cleanup" ]]; then
  step "Cleanup mode: tearing down cluster"
  if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
    if command -v kind &>/dev/null && kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
      kind delete cluster --name "${CLUSTER_NAME}"
      log "KinD cluster '${CLUSTER_NAME}' deleted"
    fi
  else
    if command -v k3s &>/dev/null; then
      sudo systemctl stop k3s
      if [[ -f /usr/local/bin/k3s-uninstall.sh ]]; then
        sudo /usr/local/bin/k3s-uninstall.sh
        log "k3s uninstalled"
      fi
    fi
  fi
  exit 0
fi

mkdir -p "${OUTPUT_DIR}"

# --------------------------------------------------------------------------
# STEP 0 — Prerequisites check
# --------------------------------------------------------------------------
step "0/12 Checking prerequisites"

declare -A INSTALL_HINTS=(
  [docker]="https://docs.docker.com/engine/install/"
  [kubectl]="https://kubernetes.io/docs/tasks/tools/#kubectl"
  [curl]="apt install curl / brew install curl"
  [jq]="apt install jq / brew install jq"
  [python3]="apt install python3 / brew install python3"
)

if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
  INSTALL_HINTS[kind]="go install sigs.k8s.io/kind@${KIND_VERSION} or see https://kind.sigs.k8s.io/"
fi

MISSING=0
REQUIRED_TOOLS=(curl jq python3)
[[ "${CLUSTER_TYPE}" == "kind" ]] && REQUIRED_TOOLS+=(docker)

for c in "${REQUIRED_TOOLS[@]}"; do
  if command -v "$c" &>/dev/null; then
    log "✔ ${c} found: $(${c} --version 2>&1 | head -1)"
  else
    err "✘ ${c} not found. Install: ${INSTALL_HINTS[$c]}"
    MISSING=1
  fi
done

[[ $MISSING -eq 1 ]] && { err "Install missing prerequisites and re-run."; exit 1; }

# Check Docker daemon if using KinD
if [[ "${CLUSTER_TYPE}" == "kind" ]] && ! docker info &>/dev/null; then
  err "Docker daemon not reachable. Is Docker running?"
  exit 1
fi

# Check for KVM availability
KVM_AVAILABLE=false
if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
  KVM_AVAILABLE=true
  log "✔ /dev/kvm available — hardware-accelerated virtualization enabled"
else
  warn "/dev/kvm not available. KubeVirt will use TCG emulation (slower)."
fi

# inotify limits check - critical for KubeVirt
if [[ "$(uname -s)" == "Linux" ]]; then
  CUR_WATCHES=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
  CUR_INSTANCES=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)
  MIN_WATCHES=524288
  MIN_INSTANCES=512
  if [[ "${CUR_WATCHES}" -lt "${MIN_WATCHES}" || "${CUR_INSTANCES}" -lt "${MIN_INSTANCES}" ]]; then
    warn "inotify limits are low (watches=${CUR_WATCHES}, instances=${CUR_INSTANCES})"
    warn "This can cause virt-handler to crash. Fix with:"
    warn "  sudo sysctl fs.inotify.max_user_watches=1048576"
    warn "  sudo sysctl fs.inotify.max_user_instances=8192"
  else
    log "✔ inotify limits OK (watches=${CUR_WATCHES}, instances=${CUR_INSTANCES})"
  fi
fi

# --------------------------------------------------------------------------
# STEP 1 — Create Kubernetes cluster (KinD or k3s)
# --------------------------------------------------------------------------
step "1/12 Creating Kubernetes cluster (${CLUSTER_TYPE})"

if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
  # Install kind if needed
  if ! command -v kind &>/dev/null; then
    log "Installing kind ${KIND_VERSION}..."
    ARCH=$(uname -m); [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && A=arm64 || A=amd64
    curl -Lo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-$(uname -s | tr '[:upper:]' '[:lower:]')-${A}"
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
  fi

  # Check if cluster already exists
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    warn "Cluster '${CLUSTER_NAME}' already exists — reusing. Delete first for clean run:"
    warn "  kind delete cluster --name ${CLUSTER_NAME}"
  else
    KIND_CONFIG="$(mktemp /tmp/kind-config-XXXXXX.yaml)"
    TMP_FILES+=("${KIND_CONFIG}")
    cat > "${KIND_CONFIG}" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /dev
        containerPath: /dev
  - role: worker
    extraMounts:
      - hostPath: /dev
        containerPath: /dev
EOF
    kind create cluster --config "${KIND_CONFIG}" --image "kindest/node:${KIND_NODE_TAG}" --wait "${TIMEOUT_SHORT}"
  fi

  kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
  WORKER_NODE="$(kind get nodes --name "${CLUSTER_NAME}" | grep worker | head -1)"
  [[ -z "${WORKER_NODE}" ]] && { err "No worker node found"; exit 1; }
  
elif [[ "${CLUSTER_TYPE}" == "k3s" ]]; then
  # Install k3s if not already installed
  if ! command -v k3s &>/dev/null; then
    log "Installing k3s..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik --write-kubeconfig-mode=644" sh -
  fi
  
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  mkdir -p ~/.kube
  sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
  sudo chown $(id -u):$(id -g) ~/.kube/config
  
  WORKER_NODE="$(hostname)"
else
  err "Unknown CLUSTER_TYPE: ${CLUSTER_TYPE}. Must be 'kind' or 'k3s'"
  exit 1
fi

log "Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout="${TIMEOUT_MED}"
log "✔ Cluster ready. Context: $(kubectl config current-context)"

# Install Multus CNI
echo "=== Installing Multus CNI ==="
if ! kubectl get daemonset -n kube-system kube-multus-ds &> /dev/null; then
    kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml
    echo "Waiting for Multus pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=multus -n kube-system --timeout=300s
else
    echo "Multus already installed"
fi

# Install OVS on the host
echo "=== Installing Open vSwitch ==="
if ! command -v ovs-vsctl &> /dev/null; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "Installing OVS via Homebrew..."
        brew install openvswitch
        brew services start openvswitch
    elif [[ -f /etc/debian_version ]]; then
        sudo apt-get update
        sudo apt-get install -y openvswitch-switch openvswitch-common
        sudo systemctl start openvswitch-switch
    elif [[ -f /etc/redhat-release ]]; then
        sudo yum install -y openvswitch
        sudo systemctl start openvswitch
    fi
else
    echo "OVS already installed"
fi

# Create OVS bridge if it doesn't exist
echo "=== Configuring OVS Bridge ==="
if ! sudo ovs-vsctl br-exists ovs-br0 2>/dev/null; then
    sudo ovs-vsctl add-br ovs-br0
    echo "Created OVS bridge ovs-br0"
else
    echo "OVS bridge ovs-br0 already exists"
fi

# Install OVS CNI plugin
echo "=== Installing OVS CNI Plugin ==="
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ovs-cni
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ovs-cni-marker
  namespace: ovs-cni
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ovs-cni-marker
rules:
- apiGroups:
  - ""
  resources:
  - nodes
  - nodes/status
  verbs:
  - get
  - update
  - patch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ovs-cni-marker
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ovs-cni-marker
subjects:
- kind: ServiceAccount
  name: ovs-cni-marker
  namespace: ovs-cni
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ovs-cni-amd64
  namespace: ovs-cni
  labels:
    tier: node
    app: ovs-cni
spec:
  selector:
    matchLabels:
      app: ovs-cni
  template:
    metadata:
      labels:
        tier: node
        app: ovs-cni
    spec:
      hostNetwork: true
      nodeSelector:
        kubernetes.io/arch: amd64
      tolerations:
      - operator: Exists
        effect: NoSchedule
      serviceAccountName: ovs-cni-marker
      containers:
      - name: ovs-cni-plugin
        image: ghcr.io/k8snetworkplumbingwg/ovs-cni-plugin:latest
        imagePullPolicy: IfNotPresent
        resources:
          requests:
            cpu: "100m"
            memory: "50Mi"
          limits:
            cpu: "100m"
            memory: "50Mi"
        securityContext:
          privileged: true
        volumeMounts:
        - name: cnibin
          mountPath: /host/opt/cni/bin
        - name: cni
          mountPath: /host/etc/cni/net.d
      - name: ovs-cni-marker
        image: ghcr.io/k8snetworkplumbingwg/ovs-cni-plugin:latest
        imagePullPolicy: IfNotPresent
        command:
        - /marker
        args:
        - -v
        - "3"
        - -logtostderr
        - -node-name
        - \$(NODE_NAME)
        - -ovs-socket
        - unix:///host/var/run/openvswitch/db.sock
        resources:
          requests:
            cpu: "100m"
            memory: "50Mi"
          limits:
            cpu: "100m"
            memory: "50Mi"
        securityContext:
          privileged: true
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        volumeMounts:
        - name: ovs-run
          mountPath: /host/var/run/openvswitch
      volumes:
      - name: cnibin
        hostPath:
          path: /opt/cni/bin
      - name: cni
        hostPath:
          path: /etc/cni/net.d
      - name: ovs-run
        hostPath:
          path: /var/run/openvswitch
EOF

echo "Waiting for OVS CNI pods to be ready..."
kubectl wait --for=condition=ready pod -l app=ovs-cni -n ovs-cni --timeout=300s || true

# Create NetworkAttachmentDefinition for OVS
echo "=== Creating OVS Network Attachment Definition ==="
kubectl apply -f - <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ovs-net
  namespace: default
spec:
  config: '{
    "cniVersion": "0.3.1",
    "type": "ovs",
    "bridge": "ovs-br0",
    "vlan": 0
  }'
EOF

# Install KubeVirt
echo "=== Installing KubeVirt ==="
export KUBEVIRT_VERSION=$(curl -s https://api.github.com/repos/kubevirt/kubevirt/releases/latest | grep tag_name | cut -d '"' -f 4)

if ! kubectl get namespace kubevirt &> /dev/null; then
    kubectl create namespace kubevirt
fi

if ! kubectl get kubevirt -n kubevirt kubevirt &> /dev/null; then
    kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml
    echo "Waiting for KubeVirt operator to be ready..."
    kubectl wait --for=condition=ready pod -l kubevirt.io=virt-operator -n kubevirt --timeout=300s
    
    kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml
else
    echo "KubeVirt already installed"
fi

# Enable emulation for non-nested virtualization environments (Apple Silicon/macOS)
echo "=== Configuring KubeVirt with emulation support ==="
kubectl patch kubevirt kubevirt -n kubevirt --type=merge -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'

echo "Waiting for KubeVirt to be ready..."
kubectl wait --for=condition=Available kubevirt kubevirt -n kubevirt --timeout=600s

# Wait for virt-handler pods
echo "Waiting for virt-handler pods to be ready..."
kubectl wait --for=condition=ready pod -l kubevirt.io=virt-handler -n kubevirt --timeout=300s

# Wait for virt-api pods
echo "Waiting for virt-api pods to be ready..."
kubectl wait --for=condition=ready pod -l kubevirt.io=virt-api -n kubevirt --timeout=300s

# Wait for virt-controller pods
echo "Waiting for virt-controller pods to be ready..."
kubectl wait --for=condition=ready pod -l kubevirt.io=virt-controller -n kubevirt --timeout=300s

# Install virtctl
echo "=== Installing virtctl ==="
if ! command -v virtctl &> /dev/null; then
    VIRTCTL_VERSION=${KUBEVIRT_VERSION}
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if [[ $(uname -m) == "arm64" ]]; then
            curl -L -o virtctl https://github.com/kubevirt/kubevirt/releases/download/${VIRTCTL_VERSION}/virtctl-${VIRTCTL_VERSION}-darwin-arm64
        else
            curl -L -o virtctl https://github.com/kubevirt/kubevirt/releases/download/${VIRTCTL_VERSION}/virtctl-${VIRTCTL_VERSION}-darwin-amd64
        fi
    else
        curl -L -o virtctl https://github.com/kubevirt/kubevirt/releases/download/${VIRTCTL_VERSION}/virtctl-${VIRTCTL_VERSION}-linux-amd64
    fi
    chmod +x virtctl
    sudo mv virtctl /usr/local/bin/
else
    echo "virtctl already installed"
fi

echo ""
echo "=== Cluster Setup Complete ==="
echo "Cluster Name: ${CLUSTER_NAME}"
echo "Kubeconfig: ${KUBECONFIG_PATH}"
echo ""
echo "Installed Components:"
echo "- Kubernetes (k3s)"
echo "- Multus CNI"
echo "- OVS CNI Plugin"
echo "- Open vSwitch Bridge (ovs-br0)"
echo "- KubeVirt with emulation enabled"
echo "- virtctl CLI"
echo ""
echo "NetworkAttachmentDefinition 'ovs-net' created in default namespace"
echo ""
echo "You can now deploy VMs using KubeVirt with Multus and OVS networking."


# --------------------------------------------------------------------------
# STEP 2 — Install standard CNI plugins
# --------------------------------------------------------------------------
step "2/12 Installing standard CNI plugins"
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-v1.4.1}"

if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
  kind get nodes --name "${CLUSTER_NAME}" | while read -r NODE; do
    docker exec -e CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION}" "${NODE}" bash -euo pipefail -c '
      [[ -f /opt/cni/bin/bridge ]] && exit 0
      ARCH=$(uname -m); [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && A=arm64 || A=amd64
      curl -sSL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${A}-${CNI_PLUGINS_VERSION}.tgz" \
        | tar -xz -C /opt/cni/bin
    '
  done
else
  # For k3s
  if [[ ! -f /opt/cni/bin/bridge ]]; then
    ARCH=$(uname -m); [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && A=arm64 || A=amd64
    sudo mkdir -p /opt/cni/bin
    curl -sSL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${A}-${CNI_PLUGINS_VERSION}.tgz" \
      | sudo tar -xz -C /opt/cni/bin
  fi
fi
log "✔ CNI plugin binaries present"

# --------------------------------------------------------------------------
# STEP 3 — Install Multus CNI
# --------------------------------------------------------------------------
step "3/12 Installing Multus CNI (${MULTUS_VERSION})"
MULTUS_URL="https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${MULTUS_VERSION}/deployments/multus-daemonset-thick.yml"
kubectl apply -f "${MULTUS_URL}"

log "Waiting for Multus DaemonSet..."
retry 30 10 "Multus DaemonSet rollout" -- kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout="${TIMEOUT_LONG}"

retry 20 5 "NetworkAttachmentDefinition CRD" -- kubectl get crd network-attachment-definitions.k8s.cni.cncf.io &>/dev/null
log "✔ Multus Ready, NetworkAttachmentDefinition CRD present"

# --------------------------------------------------------------------------
# STEP 4 — Install and Configure Open vSwitch
# --------------------------------------------------------------------------
step "4/12 Installing Open vSwitch and creating bridge ${OVS_BRIDGE_NAME}"

if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
  kind get nodes --name "${CLUSTER_NAME}" | while read -r NODE; do
    log "  Configuring OVS on node: ${NODE}"
    docker exec -e OVS_BRIDGE_NAME="${OVS_BRIDGE_NAME}" -e OVS_VLAN="${OVS_VLAN}" -e OVS_HOST_IP="${OVS_HOST_IP}" "${NODE}" bash -euo pipefail -c '
      if ! command -v ovs-vsctl &>/dev/null; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openvswitch-switch iproute2 iputils-ping
      fi
      
      # Start OVS
      /usr/share/openvswitch/scripts/ovs-ctl start --system-id=random 2>/dev/null \
        || systemctl start openvswitch-switch 2>/dev/null \
        || service openvswitch-switch start 2>/dev/null || true
      
      # Verify OVS is running
      ovs-vsctl show &>/dev/null || { echo "OVS failed to start" >&2; exit 1; }

      # Create bridge
      ovs-vsctl --may-exist add-br "${OVS_BRIDGE_NAME}" -- set bridge "${OVS_BRIDGE_NAME}" datapath_type=system
      ovs-vsctl set port "${OVS_BRIDGE_NAME}" tag="${OVS_VLAN}"
      ip link set "${OVS_BRIDGE_NAME}" up
      ip addr show dev "${OVS_BRIDGE_NAME}" | grep -q "${OVS_HOST_IP}/24" \
        || ip addr add "${OVS_HOST_IP}/24" dev "${OVS_BRIDGE_NAME}"
      
      # Verify bridge exists
      ovs-vsctl br-exists "${OVS_BRIDGE_NAME}"
      echo "OVS bridge ${OVS_BRIDGE_NAME} configured successfully"
    '
  done
else
  # For k3s (bare metal)
  if ! command -v ovs-vsctl &>/dev/null; then
    log "Installing OVS..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
      brew install openvswitch
      brew services start openvswitch
    elif [[ -f /etc/debian_version ]]; then
      sudo apt-get update
      sudo apt-get install -y openvswitch-switch openvswitch-common
      sudo systemctl start openvswitch-switch
    elif [[ -f /etc/redhat-release ]]; then
      sudo yum install -y openvswitch
      sudo systemctl start openvswitch
    fi
  fi
  
  # Create bridge
  if ! sudo ovs-vsctl br-exists "${OVS_BRIDGE_NAME}" 2>/dev/null; then
    sudo ovs-vsctl add-br "${OVS_BRIDGE_NAME}"
    sudo ovs-vsctl set port "${OVS_BRIDGE_NAME}" tag="${OVS_VLAN}"
    sudo ip link set "${OVS_BRIDGE_NAME}" up
    sudo ip addr add "${OVS_HOST_IP}/24" dev "${OVS_BRIDGE_NAME}"
  fi
fi

log "✔ OVS bridge ${OVS_BRIDGE_NAME} ready (VLAN ${OVS_VLAN}, host IP ${OVS_HOST_IP}/24)"

# --------------------------------------------------------------------------
# STEP 5 — Install OVS CNI plugin
# --------------------------------------------------------------------------
step "5/12 Installing OVS CNI plugin (${OVS_CNI_VERSION})"
OVS_CNI_MANIFEST="https://raw.githubusercontent.com/k8snetworkplumbingwg/ovs-cni/${OVS_CNI_VERSION}/examples/ovs-cni.yml"
kubectl apply -f "${OVS_CNI_MANIFEST}"

# Wait for daemonsets
for DS in ovs-cni-marker ovs-cni-plugin ovs-cni-amd64; do
  if kubectl -n kube-system get daemonset "${DS}" &>/dev/null; then
    retry 20 10 "${DS} DaemonSet" -- kubectl -n kube-system rollout status "daemonset/${DS}" --timeout="${TIMEOUT_MED}"
    log "✔ ${DS} rolled out"
  fi
done

log "✔ OVS CNI plugin installed"

# --------------------------------------------------------------------------
# STEP 6 — Install KubeVirt (with emulation support)
# --------------------------------------------------------------------------
step "6/12 Installing KubeVirt (${KUBEVIRT_VERSION})"

KV_BASE="https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}"
kubectl apply -f "${KV_BASE}/kubevirt-operator.yaml"
kubectl -n kubevirt rollout status deployment/virt-operator --timeout="${TIMEOUT_LONG}"
kubectl apply -f "${KV_BASE}/kubevirt-cr.yaml"

# Enable emulation if no KVM
if [[ "${KVM_AVAILABLE}" == "false" ]]; then
  retry 20 5 "KubeVirt CR creation" -- kubectl -n kubevirt get kubevirt kubevirt &>/dev/null
  kubectl -n kubevirt patch kubevirt kubevirt --type=merge \
    -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
  log "✔ useEmulation=true patched (no /dev/kvm)"
fi

log "Waiting for KubeVirt to become ready..."
retry 90 10 "KubeVirt deployment" -- bash -c '
  PHASE=$(kubectl -n kubevirt get kubevirt kubevirt -o jsonpath="{.status.phase}" 2>/dev/null || echo "")
  [[ "${PHASE}" == "Deployed" ]]
'

kubectl -n kubevirt rollout status deployment/virt-api --timeout="${TIMEOUT_LONG}"
kubectl -n kubevirt rollout status deployment/virt-controller --timeout="${TIMEOUT_LONG}"
kubectl -n kubevirt rollout status daemonset/virt-handler --timeout="${TIMEOUT_LONG}"
log "✔ KubeVirt deployed (virt-api, virt-controller, virt-handler ready)"

# --------------------------------------------------------------------------
# STEP 7 — Install virtctl
# --------------------------------------------------------------------------
step "7/12 Installing virtctl"
VIRTCTL="${HOME}/.local/bin/virtctl"
mkdir -p "$(dirname "${VIRTCTL}")"
if [[ ! -x "${VIRTCTL}" ]]; then
  ARCH=$(uname -m); [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && A=arm64 || A=amd64
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  curl -fsSL -o "${VIRTCTL}" "${KV_BASE}/virtctl-${KUBEVIRT_VERSION}-${OS}-${A}"
  chmod +x "${VIRTCTL}"
fi
export PATH="${HOME}/.local/bin:${PATH}"
log "✔ virtctl installed: $(virtctl version --client 2>&1 | head -1 || echo 'installed')"

# --------------------------------------------------------------------------
# STEP 8 — Create NetworkAttachmentDefinition
# --------------------------------------------------------------------------
step "8/12 Creating NetworkAttachmentDefinition"
cat <<EOF | kubectl apply -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ovs-net
  namespace: default
spec:
  config: '{
    "cniVersion": "0.4.0",
    "type": "ovs",
    "bridge": "${OVS_BRIDGE_NAME}",
    "vlan": ${OVS_VLAN},
    "mtu": 1500,
    "ipam": {}
  }'
EOF
log "✔ NetworkAttachmentDefinition 'ovs-net' created"

# --------------------------------------------------------------------------
# STEP 9 — Apply VM manifests
# --------------------------------------------------------------------------
step "9/12 Applying VirtualMachine manifests"
if [[ -f "$(dirname "$0")/manifests.yaml" ]]; then
  kubectl apply -f "$(dirname "$0")/manifests.yaml"
  log "✔ VirtualMachine resources applied"
else
  warn "manifests.yaml not found, skipping VM deployment"
fi

# --------------------------------------------------------------------------
# STEP 10 — Wait for VMs to be ready
# --------------------------------------------------------------------------
step "10/12 Waiting for VirtualMachines to be ready"
VM_NAME="${VM_NAME:-vm-cirros}"
retry 30 10 "VMI creation" -- kubectl get vmi "${VM_NAME}" &>/dev/null || {
  warn "VM ${VM_NAME} not found, skipping verification"
  log "Cluster setup complete without VM verification"
  exit 0
}

log "Waiting for VMI ${VM_NAME} to reach Running state..."
VM_BOOT_BUDGET_SECONDS=600
elapsed=0
while true; do
  PHASE=$(kubectl get vmi "${VM_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  [[ "${PHASE}" == "Running" ]] && { log "✔ VMI phase: Running"; break; }
  if [[ "${PHASE}" == "Failed" ]]; then
    err "VMI reached Failed phase"
    kubectl describe vmi "${VM_NAME}"
    exit 2
  fi
  if [[ ${elapsed} -ge ${VM_BOOT_BUDGET_SECONDS} ]]; then
    err "VMI did not reach Running within ${VM_BOOT_BUDGET_SECONDS}s"
    kubectl describe vmi "${VM_NAME}"
    exit 2
  fi
  sleep 10; elapsed=$((elapsed + 10))
  log "  VMI phase: ${PHASE} (${elapsed}s/${VM_BOOT_BUDGET_SECONDS}s)"
done

# --------------------------------------------------------------------------
# STEP 11 — Capture OVS evidence 
# --------------------------------------------------------------------------
step "11/12 Capturing OVS verification evidence"

FLOWS_RAW="${OUTPUT_DIR}/flows_raw.txt"
DATAPATH_RAW="${OUTPUT_DIR}/datapath_raw.txt"
FDB_RAW="${OUTPUT_DIR}/fdb.txt"
PORTS_RAW="${OUTPUT_DIR}/ports.txt"
BRIDGE_TOPOLOGY="${OUTPUT_DIR}/bridge_topology.txt"
EXECUTION_MODE="${OUTPUT_DIR}/execution_mode.txt"

if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
  # Capture from KinD node
  docker exec "${WORKER_NODE}" ovs-ofctl dump-flows "${OVS_BRIDGE_NAME}" > "${FLOWS_RAW}"
  docker exec "${WORKER_NODE}" ovs-appctl dpctl/dump-flows > "${DATAPATH_RAW}" 2>/dev/null || echo "N/A" > "${DATAPATH_RAW}"
  docker exec "${WORKER_NODE}" ovs-appctl fdb/show "${OVS_BRIDGE_NAME}" > "${FDB_RAW}" 2>/dev/null || echo "N/A" > "${FDB_RAW}"
  docker exec "${WORKER_NODE}" ovs-ofctl show "${OVS_BRIDGE_NAME}" > "${PORTS_RAW}"
  docker exec "${WORKER_NODE}" ovs-vsctl show > "${BRIDGE_TOPOLOGY}"
  
  # Execution mode info
  cat > "${EXECUTION_MODE}" <<EOFMODE
Execution Mode Information
==========================
Cluster Type: ${CLUSTER_TYPE}
KVM Available: ${KVM_AVAILABLE}
KubeVirt useEmulation: $([[ "${KVM_AVAILABLE}" == "false" ]] && echo "true" || echo "false")
OVS Version: $(docker exec "${WORKER_NODE}" ovs-vsctl --version 2>/dev/null | head -1)
QEMU Acceleration: $([[ "${KVM_AVAILABLE}" == "true" ]] && echo "kvm" || echo "tcg")
Node: ${WORKER_NODE}
EOFMODE
else
  # Capture from k3s
  sudo ovs-ofctl dump-flows "${OVS_BRIDGE_NAME}" > "${FLOWS_RAW}"
  sudo ovs-appctl dpctl/dump-flows > "${DATAPATH_RAW}" 2>/dev/null || echo "N/A" > "${DATAPATH_RAW}"
  sudo ovs-appctl fdb/show "${OVS_BRIDGE_NAME}" > "${FDB_RAW}" 2>/dev/null || echo "N/A" > "${FDB_RAW}"
  sudo ovs-ofctl show "${OVS_BRIDGE_NAME}" > "${PORTS_RAW}"
  sudo ovs-vsctl show > "${BRIDGE_TOPOLOGY}"
  
  cat > "${EXECUTION_MODE}" <<EOFMODE
Execution Mode Information
==========================
Cluster Type: ${CLUSTER_TYPE}
KVM Available: ${KVM_AVAILABLE}
KubeVirt useEmulation: $([[ "${KVM_AVAILABLE}" == "false" ]] && echo "true" || echo "false")
OVS Version: $(sudo ovs-vsctl --version 2>/dev/null | head -1)
Node: ${WORKER_NODE}
EOFMODE
fi

log "✔ OVS evidence captured to ${OUTPUT_DIR}/"

# --------------------------------------------------------------------------
# STEP 12 — Generate verification_flows.json
# --------------------------------------------------------------------------
step "12/12 Generating verification_flows.json"

# Create a simple Python parser inline
PARSER_SCRIPT="${OUTPUT_DIR}/flows_parser.py"
cat > "${PARSER_SCRIPT}" <<'EOFPARSER'
#!/usr/bin/env python3
import sys, json, re

def parse_flow_line(line):
    line = line.strip()
    if not line or line.startswith(("NXST_FLOW", "OFPST_FLOW")):
        return None
    
    left, _, actions_str = line.partition(" actions=")
    info, match = {}, {}
    info_keys = {"cookie", "duration", "table", "n_packets", "n_bytes",
                 "idle_age", "hard_age", "priority"}
    
    for part in left.split(", "):
        if "=" not in part:
            continue
        k, v = part.split("=", 1)
        if k == "duration" and v.endswith("s"):
            v = float(v[:-1])
        elif re.fullmatch(r"-?\d+", v):
            v = int(v)
        (info if k in info_keys else match)[k] = v
    
    return {
        "orig": line,
        "info": info,
        "match": match,
        "actions": actions_str.strip()
    }

flows = [f for f in (parse_flow_line(l) for l in sys.stdin) if f]
print(json.dumps({"flows": flows, "_meta": {"bridge": "${OVS_BRIDGE_NAME}"}}, indent=2))
EOFPARSER

chmod +x "${PARSER_SCRIPT}"
python3 "${PARSER_SCRIPT}" < "${FLOWS_RAW}" > "${OUTPUT_DIR}/verification_flows.json"

log "✔ verification_flows.json generated"

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo
log "==================== SETUP COMPLETE ===================="
log "Cluster: ${CLUSTER_NAME} (${CLUSTER_TYPE})"
log "KubeVirt: ${KUBEVIRT_VERSION}"
log "Multus: ${MULTUS_VERSION}"
log "OVS Bridge: ${OVS_BRIDGE_NAME} (VLAN ${OVS_VLAN})"
log "Evidence: ${OUTPUT_DIR}/"
log ""
log "Next steps:"
log "  1. Check VM status: kubectl get vmi"
log "  2. Console into VM: virtctl console ${VM_NAME}"
log "  3. Run verification: ./verify_datapath.sh"
log "  4. Review evidence: cat ${OUTPUT_DIR}/verification_flows.json"
log ""
log "Cleanup: ./cluster_setup.sh --cleanup"
log "========================================================"
exit 0
