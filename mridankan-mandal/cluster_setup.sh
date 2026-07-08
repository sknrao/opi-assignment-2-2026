#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
K3S_EXEC_ARGS="server --write-kubeconfig-mode 644 --disable traefik --disable servicelb --disable metrics-server"
K3S_VERSION="${K3S_VERSION:-v1.32.11+k3s1}"
MULTUS_VERSION="${MULTUS_VERSION:-v4.3.0}"
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.8.4}"
KUBEVIRT_REGISTRY="${KUBEVIRT_REGISTRY:-quay.io/kubevirt}"
KUBEVIRT_INFRA_REPLICAS="${KUBEVIRT_INFRA_REPLICAS:-1}"
KUBEVIRT_OPERATOR_REPLICAS="${KUBEVIRT_OPERATOR_REPLICAS:-1}"
VM_NAME="${VM_NAME:-ovs-vm}"
VM_SECONDARY_IP="${VM_SECONDARY_IP:-192.168.100.10}"
VM_CONTAINERDISK_IMAGE="${VM_CONTAINERDISK_IMAGE:-quay.io/kubevirt/cirros-container-disk-demo:${KUBEVIRT_VERSION}}"
LOG_PATH="${LOG_PATH:-${REPO_DIR}/cluster_setup.log}"
PING_RESULTS_PATH="${PING_RESULTS_PATH:-${REPO_DIR}/ping_results.txt}"
FLOW_RESULTS_PATH="${FLOW_RESULTS_PATH:-${REPO_DIR}/verification_flows.json}"
GUEST_PING_START_MARKER="__OPI_VM_TO_HOST_PING_START__"
GUEST_PING_END_MARKER="__OPI_VM_TO_HOST_PING_END__"
OUTPUT_OWNER="${SUDO_USER:-}"

mkdir -p "$(dirname "$LOG_PATH")"
exec > >(tee -a "$LOG_PATH") 2>&1

if [[ "${EUID}" -eq 0 ]]; then
  sudo() {
    if [[ "${1:-}" == *=* ]]; then
      env "$@"
    else
      "$@"
    fi
  }
else
  sudo -v
  while true; do
    sudo -n true
    sleep 50
    kill -0 "$$" || exit
  done 2>/dev/null &
  SUDO_KEEPALIVE_PID="$!"
  trap 'kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true' EXIT
fi

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

wait_for_ping() {
  local ip_addr="$1"
  local attempts="${2:-40}"
  local delay="${3:-5}"
  local i

  for ((i = 1; i <= attempts; i++)); do
    if sudo ip netns exec peer-ns ping -c 1 -W 2 "$ip_addr" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$delay"
  done

  return 1
}

wait_for_resource() {
  local resource="$1"
  local timeout_seconds="${2:-1800}"
  local waited=0

  until kubectl -n kubevirt get "$resource" >/dev/null 2>&1; do
    if (( waited >= timeout_seconds )); then
      printf 'timed out waiting for %s\n' "$resource" >&2
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

get_launcher_pod() {
  local vm_name="$1"

  kubectl get pod \
    -l "kubevirt.io/domain=${vm_name}" \
    -o jsonpath='{.items[0].metadata.name}'
}

extract_guest_ping_block() {
  local serial_log="$1"

  printf '%s\n' "$serial_log" \
    | tr -d '\r' \
    | sed -n "/${GUEST_PING_START_MARKER}/,/${GUEST_PING_END_MARKER}/p" \
    | sed "/${GUEST_PING_START_MARKER}/d;/${GUEST_PING_END_MARKER}/d" \
    | grep -E '^(PING |64 bytes from |--- |[0-9]+ packets transmitted|round-trip min/avg/max|rtt min/avg/max)' || true
}

wait_for_guest_ping_block() {
  local vm_name="$1"
  local attempts="${2:-48}"
  local delay="${3:-5}"
  local launcher_pod
  local serial_log
  local i

  for ((i = 1; i <= attempts; i++)); do
    launcher_pod="$(get_launcher_pod "$vm_name" 2>/dev/null || true)"
    if [[ -n "$launcher_pod" ]]; then
      serial_log="$(
        kubectl exec "$launcher_pod" -- sh -lc 'cat /var/run/kubevirt-private/*/virt-serial0-log' 2>/dev/null || true
      )"
      if [[ "$serial_log" == *"$GUEST_PING_END_MARKER"* ]]; then
        printf '%s' "$serial_log"
        return 0
      fi
    fi
    sleep "$delay"
  done

  return 1
}

fix_output_ownership() {
  if [[ -n "$OUTPUT_OWNER" ]]; then
    sudo chown "$OUTPUT_OWNER:$OUTPUT_OWNER" "$PING_RESULTS_PATH" "$FLOW_RESULTS_PATH" 2>/dev/null || true
  fi
}

prefetch_kubevirt_image() {
  local image_ref="$1"

  if ! command -v crictl >/dev/null 2>&1; then
    return 0
  fi

  if ! sudo crictl pull "$image_ref"; then
    log "warning: failed to pre-pull ${image_ref}"
  fi
}

dump_ovs_flows_json() {
  local ofctl_raw
  local bridge_raw
  local fdb_raw
  local ports_raw
  local ovs_show_raw
  local ovs_version

  ofctl_raw="$(sudo ovs-ofctl dump-flows br-ovs)"
  bridge_raw="$(sudo ovs-appctl bridge/dump-flows br-ovs)"
  fdb_raw="$(sudo ovs-appctl fdb/show br-ovs 2>/dev/null || true)"
  ports_raw="$(sudo ovs-ofctl dump-ports br-ovs 2>/dev/null || true)"
  ovs_show_raw="$(sudo ovs-vsctl show)"
  ovs_version="$(sudo ovs-vsctl --version | sed -n '1p')"

  jq -Rn \
    --arg bridge "br-ovs" \
    --arg ovs_version "$ovs_version" \
    --arg ofctl_command "ovs-ofctl dump-flows br-ovs" \
    --arg ofctl_raw "$ofctl_raw" \
    --arg bridge_command "ovs-appctl bridge/dump-flows br-ovs" \
    --arg bridge_raw "$bridge_raw" \
    --arg fdb_command "ovs-appctl fdb/show br-ovs" \
    --arg fdb_raw "$fdb_raw" \
    --arg ports_command "ovs-ofctl dump-ports br-ovs" \
    --arg ports_raw "$ports_raw" \
    --arg ovs_show_command "ovs-vsctl show" \
    --arg ovs_show_raw "$ovs_show_raw" '
      def lines($raw):
        $raw
        | split("\n")
        | map(gsub("\r$"; ""))
        | map(select(length > 0));
      def flow_lines($raw):
        lines($raw)
        | map(select(startswith("NXST_FLOW reply") | not));
      def capture_or_null($line; $pattern):
        if $line | test($pattern) then
          ($line | capture($pattern).value)
        else
          null
        end;
      def capture_num_or_null($line; $pattern):
        capture_or_null($line; $pattern)
        | if . == null then null else tonumber end;
      def parse_flow($line):
        {
          raw: $line,
          cookie: capture_or_null($line; "cookie=(?<value>[^, ]+)"),
          table: (
            if $line | test("table_id=") then
              capture_num_or_null($line; "table_id=(?<value>[0-9]+)")
            elif $line | test("table=") then
              capture_num_or_null($line; "table=(?<value>[0-9]+)")
            else
              null
            end
          ),
          duration: capture_or_null($line; "duration=(?<value>[^, ]+)"),
          n_packets: capture_num_or_null($line; "n_packets=(?<value>[0-9]+)"),
          n_bytes: capture_num_or_null($line; "n_bytes=(?<value>[0-9]+)"),
          idle_age: capture_num_or_null($line; "idle_age=(?<value>[0-9]+)"),
          priority: capture_num_or_null($line; "priority=(?<value>[0-9]+)"),
          actions: capture_or_null($line; "actions=(?<value>.*)$")
        };
      def parse_fdb_entries($raw):
        lines($raw)
        | map(
            if test("^[[:space:]]*(LOCAL|[0-9]+)[[:space:]]+[0-9]+[[:space:]]+[0-9A-Fa-f:]{17}[[:space:]]+[0-9]+$") then
              capture("^[[:space:]]*(?<port>LOCAL|[0-9]+)[[:space:]]+(?<vlan>[0-9]+)[[:space:]]+(?<mac>[0-9A-Fa-f:]{17})[[:space:]]+(?<age>[0-9]+)$")
              | {
                  port: .port,
                  vlan: (.vlan | tonumber),
                  mac: (.mac | ascii_downcase),
                  age: (.age | tonumber)
                }
            else
              empty
            end
          );
      {
        bridge: $bridge,
        metadata: {
          ovs_version: $ovs_version,
          native_json_supported: false,
          note: "Local OVS build lacks native ovs-ofctl JSON output, so this file preserves raw dumps plus structured parsing."
        },
        openflow_dump: {
          source_command: $ofctl_command,
          raw: $ofctl_raw,
          flow_count: (flow_lines($ofctl_raw) | length),
          flows: (flow_lines($ofctl_raw) | map(parse_flow(.)))
        },
        datapath_dump: {
          source_command: $bridge_command,
          raw: $bridge_raw,
          flow_count: (flow_lines($bridge_raw) | length),
          flows: (flow_lines($bridge_raw) | map(parse_flow(.)))
        },
        fdb_dump: {
          source_command: $fdb_command,
          raw: $fdb_raw,
          entry_count: (parse_fdb_entries($fdb_raw) | length),
          entries: parse_fdb_entries($fdb_raw)
        },
        port_stats_dump: {
          source_command: $ports_command,
          raw: $ports_raw
        },
        ovs_vsctl_show: {
          source_command: $ovs_show_command,
          raw: $ovs_show_raw
        }
      }
    '
}

log "installing host packages"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  openvswitch-switch \
  containernetworking-plugins \
  jq \
  curl \
  ca-certificates \
  iproute2 \
  bridge-utils \
  iputils-ping

log "starting openvswitch"
sudo systemctl enable --now openvswitch-switch

if ! systemctl is-active --quiet k3s; then
  log "installing k3s $K3S_VERSION"
  curl -fsSL https://get.k3s.io | sudo env INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC="$K3S_EXEC_ARGS" sh -
fi

log "waiting for k3s"
sudo systemctl enable --now k3s
sudo systemctl is-active --quiet k3s

export KUBECONFIG="$KUBECONFIG_PATH"
rm -f "$PING_RESULTS_PATH" "$FLOW_RESULTS_PATH"

need_cmd kubectl
need_cmd ovs-vsctl
need_cmd ovs-ofctl

log "waiting for kubernetes node readiness"
kubectl wait --for=condition=Ready node --all --timeout=10m

log "building local OVS and bridge topology"
sudo ip link add br-vm type bridge 2>/dev/null || true
sudo ip link set br-vm up

sudo ovs-vsctl --may-exist add-br br-ovs
sudo ip link set br-ovs up

if ! ip link show veth-brvm >/dev/null 2>&1; then
  sudo ip link add veth-brvm type veth peer name veth-ovs
fi

sudo ip link set veth-brvm master br-vm
sudo ip link set veth-brvm up
sudo ovs-vsctl --may-exist add-port br-ovs veth-ovs
sudo ip link set veth-ovs up

sudo ip netns add peer-ns 2>/dev/null || true
if ! ip link show peer-host >/dev/null 2>&1; then
  sudo ip link add peer-host type veth peer name peer-ns0
  sudo ip link set peer-ns0 netns peer-ns
fi

sudo ovs-vsctl --may-exist add-port br-ovs peer-host
sudo ip link set peer-host up
sudo ip -n peer-ns link set lo up
sudo ip -n peer-ns addr flush dev peer-ns0 || true
sudo ip -n peer-ns addr add 192.168.100.1/24 dev peer-ns0
sudo ip -n peer-ns link set peer-ns0 up

sudo ovs-ofctl del-flows br-ovs || true
sudo ovs-ofctl add-flow br-ovs "priority=0,actions=NORMAL"

log "installing multus thin plugin locally"
kubectl -n kube-system delete daemonset/kube-multus-ds --ignore-not-found
kubectl -n kube-system delete configmap/multus-daemon-config --ignore-not-found
tmp_multus_dir="$(mktemp -d)"
tmp_multus_archive="${tmp_multus_dir}/multus.tar.gz"
multus_release_dir="multus-cni_${MULTUS_VERSION#v}_linux_amd64"
curl -fsSL \
  "https://github.com/k8snetworkplumbingwg/multus-cni/releases/download/${MULTUS_VERSION}/multus-cni_${MULTUS_VERSION#v}_linux_amd64.tar.gz" \
  -o "$tmp_multus_archive"
tar -xzf "$tmp_multus_archive" -C "$tmp_multus_dir"
sudo install -d /var/lib/rancher/k3s/data/current/bin /var/lib/rancher/k3s/data/cni
sudo install -m 755 \
  "${tmp_multus_dir}/${multus_release_dir}/multus" \
  /var/lib/rancher/k3s/data/current/bin/multus
sudo install -m 755 \
  "${tmp_multus_dir}/${multus_release_dir}/multus" \
  /var/lib/rancher/k3s/data/cni/multus

kubectl apply -f - <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: network-attachment-definitions.k8s.cni.cncf.io
spec:
  group: k8s.cni.cncf.io
  scope: Namespaced
  names:
    plural: network-attachment-definitions
    singular: network-attachment-definition
    kind: NetworkAttachmentDefinition
    shortNames:
      - nad
      - net-attach-def
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                config:
                  type: string
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: multus
  namespace: kube-system
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: multus
rules:
  - apiGroups: ["k8s.cni.cncf.io"]
    resources:
      - '*'
    verbs:
      - '*'
  - apiGroups:
      - ""
    resources:
      - pods
      - pods/status
    verbs:
      - get
      - list
      - update
      - watch
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: multus
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: multus
subjects:
  - kind: ServiceAccount
    name: multus
    namespace: kube-system
EOF

multus_token="$(kubectl -n kube-system create token multus --duration=720h)"
multus_ca="$(base64 -w 0 /var/lib/rancher/k3s/server/tls/server-ca.crt)"
sudo mkdir -p /var/lib/rancher/k3s/agent/etc/cni/net.d/multus.d
sudo tee /var/lib/rancher/k3s/agent/etc/cni/net.d/multus.d/multus.kubeconfig >/dev/null <<EOF
apiVersion: v1
kind: Config
clusters:
- name: local
  cluster:
    server: https://127.0.0.1:6443
    certificate-authority-data: ${multus_ca}
users:
- name: multus
  user:
    token: "${multus_token}"
contexts:
- name: multus-context
  context:
    cluster: local
    user: multus
current-context: multus-context
EOF
sudo chmod 600 /var/lib/rancher/k3s/agent/etc/cni/net.d/multus.d/multus.kubeconfig
sudo tee /var/lib/rancher/k3s/agent/etc/cni/net.d/00-multus.conf >/dev/null <<'EOF'
{
  "cniVersion": "1.0.0",
  "name": "multus-cni-network",
  "type": "multus",
  "readinessindicatorfile": "/run/flannel/subnet.env",
  "kubeconfig": "/var/lib/rancher/k3s/agent/etc/cni/net.d/multus.d/multus.kubeconfig",
  "clusterNetwork": "/var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist"
}
EOF
rm -rf "$tmp_multus_dir"

if ! kubectl -n kubevirt get kubevirt kubevirt >/dev/null 2>&1; then
  log "installing kubevirt $KUBEVIRT_VERSION"
  kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
  kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"
fi

log "forcing kubevirt emulation plus WSL-compatible feature gates"
kubectl -n kubevirt patch kubevirt kubevirt --type merge -p \
  "{\"spec\":{\"infra\":{\"replicas\":${KUBEVIRT_INFRA_REPLICAS}},\"configuration\":{\"developerConfiguration\":{\"featureGates\":[\"Root\",\"HostDisk\"],\"useEmulation\":true}}}}"

log "scaling kubevirt operator for single-node lab"
kubectl -n kubevirt scale deployment/virt-operator --replicas="$KUBEVIRT_OPERATOR_REPLICAS"

log "pre-pulling kubevirt images"
prefetch_kubevirt_image "${KUBEVIRT_REGISTRY}/virt-operator:${KUBEVIRT_VERSION}"
prefetch_kubevirt_image "${KUBEVIRT_REGISTRY}/virt-api:${KUBEVIRT_VERSION}"
prefetch_kubevirt_image "${KUBEVIRT_REGISTRY}/virt-controller:${KUBEVIRT_VERSION}"
prefetch_kubevirt_image "${KUBEVIRT_REGISTRY}/virt-handler:${KUBEVIRT_VERSION}"
prefetch_kubevirt_image "${KUBEVIRT_REGISTRY}/virt-launcher:${KUBEVIRT_VERSION}"
prefetch_kubevirt_image "${VM_CONTAINERDISK_IMAGE}"

log "waiting for kubevirt"
wait_for_resource deployment/virt-api 1800
wait_for_resource deployment/virt-controller 1800
wait_for_resource daemonset/virt-handler 1800
kubectl -n kubevirt rollout status deployment/virt-api --timeout=30m
kubectl -n kubevirt rollout status deployment/virt-controller --timeout=30m
kubectl -n kubevirt rollout status daemonset/virt-handler --timeout=30m
kubectl -n kubevirt rollout status deployment/virt-operator --timeout=30m
kubectl -n kubevirt wait kubevirt/kubevirt --for=jsonpath='{.status.phase}'=Deployed --timeout=30m

log "preparing kubevirt runtime directories"
sudo install -d \
  /var/run/kubevirt-ephemeral-disks/cloud-init-data \
  /var/run/kubevirt-ephemeral-disks/container-disk-data \
  /var/run/kubevirt/container-disks

log "replacing existing vm if present"
kubectl delete vm "$VM_NAME" --ignore-not-found --wait=true

log "applying assignment manifests"
kubectl apply -f "$REPO_DIR/manifests.yaml"

log "waiting for vm readiness"
kubectl wait --for=condition=Ready "vmi/${VM_NAME}" --timeout=60m

log "waiting for guest secondary network"
if ! wait_for_ping "$VM_SECONDARY_IP" 96 5; then
  kubectl get vmi "$VM_NAME" -o wide
  kubectl get pods -A
  sudo ovs-vsctl show
  exit 1
fi

log "capturing raw ping results"
host_ping_output="$(sudo ip netns exec peer-ns ping -c 4 -W 2 "$VM_SECONDARY_IP")"

log "capturing guest-to-host ping from serial log"
guest_serial_log="$(wait_for_guest_ping_block "$VM_NAME" 48 5)"
guest_ping_output="$(extract_guest_ping_block "$guest_serial_log")"
if [[ -z "$guest_ping_output" ]]; then
  printf 'guest serial log did not contain ping output markers\n' >&2
  exit 1
fi
if [[ "$guest_ping_output" != *"0% packet loss"* ]]; then
  printf 'guest-to-host ping did not report success\n' >&2
  printf '%s\n' "$guest_ping_output" >&2
  exit 1
fi

printf '%s\n%s\n' "$host_ping_output" "$guest_ping_output" >"$PING_RESULTS_PATH"

log "capturing ovs flows as json"
dump_ovs_flows_json >"$FLOW_RESULTS_PATH"
fix_output_ownership

log "done"
