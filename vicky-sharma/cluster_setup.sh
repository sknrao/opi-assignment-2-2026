#!/usr/bin/env bash
#
# cluster_setup.sh, bootstrap a local Kubernetes datapath lab for the OPI OVS challenge.
#
# Stack: k3s (single node) + Open vSwitch + Multus CNI + OVS-CNI + KubeVirt.
# Target: an Ubuntu Linux host. Verified on Ubuntu 24.04 (single-node k3s), 
# see ASSUMPTIONS.md for the environment and results.
#
# Design choices (see ASSUMPTIONS.md for rationale):
#   * OVS runs directly on the node (k3s node == host), so ovs-cni sees a REAL ovsdb + bridge.
#   * OVS uses the USERSPACE datapath (datapath_type=netdev) so it needs no kernel module, this
#     is what makes it work even where the openvswitch.ko kernel module can't be loaded.
#   * k3s stores CNI conf/bin in non-standard paths; this script patches Multus/OVS-CNI for them.
#
# Idempotent-ish: safe to re-run; each phase checks before acting.
#
# Usage:
#   ./cluster_setup.sh            # full bootstrap
#   ./cluster_setup.sh verify     # ping test + OVS flow dump -> ping_results.txt + verification_flows.json
#
# Pinned versions (latest stable as of 2026-07-02):
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.8.4}"
MULTUS_VERSION="${MULTUS_VERSION:-v4.3.0}"
OVS_CNI_VERSION="${OVS_CNI_VERSION:-v0.39.0}"
OVS_BRIDGE="${OVS_BRIDGE:-br-ovs}"

# k3s CNI paths (discovered on the running k3s node):
K3S_CNI_CONF="/var/lib/rancher/k3s/agent/etc/cni/net.d"
K3S_CNI_BIN_STAGE="/var/lib/rancher/k3s/data/current/bin"   # writable; daemonsets copy here
K3S_CNI_BIN_LIVE="/var/lib/rancher/k3s/data/cni"            # what containerd actually invokes

set -uo pipefail
log()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*"; }
KC="/etc/rancher/k3s/k3s.yaml"
kc() { sudo KUBECONFIG="$KC" kubectl "$@"; }

# ---------------------------------------------------------------------------
phase_ovs() {
  log "Phase 1/5: Open vSwitch (userspace datapath)"
  command -v ovs-vsctl >/dev/null 2>&1 || { sudo apt-get update -qq; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openvswitch-switch openvswitch-common; }
  sudo mkdir -p /var/run/openvswitch /etc/openvswitch
  # Start ovsdb-server + ovs-vswitchd MANUALLY (ovs-ctl insists on the kernel module, which we
  # don't have; userspace vswitchd works fine as long as bridges use datapath_type=netdev).
  if ! pgrep -f ovsdb-server >/dev/null; then
    [ -f /etc/openvswitch/conf.db ] || sudo ovsdb-tool create /etc/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema
    sudo ovsdb-server /etc/openvswitch/conf.db \
      --remote=punix:/var/run/openvswitch/db.sock \
      --remote=db:Open_vSwitch,Open_vSwitch,manager_options --pidfile --detach --log-file >/dev/null 2>&1
    sudo ovs-vsctl --no-wait init
  fi
  pgrep -f ovs-vswitchd >/dev/null || sudo ovs-vswitchd --pidfile --detach --log-file >/dev/null 2>&1
  sudo ovs-vsctl --may-exist add-br "$OVS_BRIDGE" -- set bridge "$OVS_BRIDGE" datapath_type=netdev
  sudo ip link set "$OVS_BRIDGE" up
  sudo ovs-vsctl show
}

# ---------------------------------------------------------------------------
phase_k3s() {
  log "Phase 2/5: k3s single-node cluster"
  if ! command -v k3s >/dev/null 2>&1; then
    # Install the binary but don't let the installer start/enable k3s, we start it ourselves below
    # with the flags we want. `sudo env VAR=... sh -` reliably passes the INSTALL_K3S_* vars into the
    # installer regardless of the sudoers env policy (a bare `VAR=... sh -` after an empty sudo/root
    # is mis-parsed as a command).
    curl -sfL https://get.k3s.io | sudo env INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true sh -
  fi
  if [ ! -f "$KC" ] || ! kc get nodes >/dev/null 2>&1; then
    sudo bash -c 'setsid k3s server --snapshotter=native --write-kubeconfig-mode=644 \
      --disable traefik --disable servicelb --flannel-backend=host-gw >/var/log/k3s.log 2>&1 </dev/null &'
  fi
  log "waiting for node Ready..."
  for i in $(seq 1 40); do kc get nodes 2>/dev/null | grep -q ' Ready' && break; sleep 3; done
  kc get nodes -o wide
}

# ---------------------------------------------------------------------------
phase_cni_prereqs() {
  log "Phase 3/5: CNI prerequisites for k3s"
  # Multus' binary-installer uses bidirectional mount propagation; the mount source must be shared.
  sudo mount --make-rshared / 2>/dev/null || warn "make-rshared / failed (needed for Multus binary install)"
  # Multus writes its kubeconfig with an absolute /etc/cni/net.d/... path; make that resolve on k3s.
  sudo mkdir -p /etc/cni
  [ -e /etc/cni/net.d ] || sudo ln -sfn "$K3S_CNI_CONF" /etc/cni/net.d
}

# ---------------------------------------------------------------------------
phase_multus_ovscni() {
  log "Phase 4/5: Multus + OVS-CNI (patched for k3s paths)"
  local murl="https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${MULTUS_VERSION}/deployments/multus-daemonset.yml"
  local ourl="https://raw.githubusercontent.com/k8snetworkplumbingwg/ovs-cni/${OVS_CNI_VERSION}/examples/ovs-cni.yml"
  curl -sfL "$murl" -o /tmp/multus.yml
  curl -sfL "$ourl" -o /tmp/ovs-cni.yml
  # Repoint the daemonsets' hostPath volumes to the k3s CNI conf/bin dirs.
  sed -i -e "s#path: /etc/cni/net.d#path: ${K3S_CNI_CONF}#" -e "s#path: /opt/cni/bin#path: ${K3S_CNI_BIN_STAGE}#" /tmp/multus.yml
  sed -i -e "s#path: /opt/cni/bin#path: ${K3S_CNI_BIN_STAGE}#" /tmp/ovs-cni.yml
  kc apply -f /tmp/multus.yml
  kc apply -f /tmp/ovs-cni.yml
  kc -n kube-system rollout status ds/kube-multus-ds --timeout=240s || warn "multus slow"
  kc -n kube-system rollout status ds/ovs-cni-amd64 --timeout=240s || warn "ovs-cni slow"
  # containerd invokes plugins from K3S_CNI_BIN_LIVE (symlink dir), NOT the staging bin dir the
  # daemonsets copied into, so copy the real multus/ovs binaries where containerd looks.
  log "placing multus/ovs binaries in the live CNI dir"
  for b in multus ovs ovs-mirror-consumer ovs-mirror-producer; do
    [ -f "${K3S_CNI_BIN_STAGE}/$b" ] && sudo cp -f "${K3S_CNI_BIN_STAGE}/$b" "${K3S_CNI_BIN_LIVE}/$b"
  done
  # Multus' init container stages its binary asynchronously; if a slow image pull made the rollout
  # wait above time out, `multus` may not have been staged yet when we copied. Guarantee it's present.
  if [ ! -f "${K3S_CNI_BIN_LIVE}/multus" ]; then
    local m; m=$(find /var/lib/rancher/k3s -type f -name multus 2>/dev/null | head -1)
    [ -n "$m" ] && { sudo cp -f "$m" "${K3S_CNI_BIN_LIVE}/multus"; log "recovered multus binary from $m"; } \
                || warn "multus binary not found yet, re-run this phase once the multus pod is Running"
  fi
}

# ---------------------------------------------------------------------------
phase_kubevirt() {
  log "Phase 5/5: KubeVirt ${KUBEVIRT_VERSION}"
  kc apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
  kc apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"
  # Force software emulation (QEMU TCG). This is what the captured run used: it guarantees the VM
  # boots regardless of whether the node exposes a usable /dev/kvm to virt-launcher. CirrOS is tiny,
  # so emulation is fast enough; on a host with working KVM passthrough you may drop this for speed.
  kc -n kubevirt patch kubevirt kubevirt --type=merge \
      -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
  log "waiting for KubeVirt Available (image pulls can take 10-20 min on a fresh node)..."
  kc -n kubevirt wait kv kubevirt --for=condition=Available --timeout=1200s || warn "KubeVirt not Available yet"
  # NOTE: KubeVirt VM boot needs a few GB of free-disk headroom on the node.
  # Install virtctl for console/ping:
  command -v virtctl >/dev/null 2>&1 || {
    sudo curl -sL "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64" -o /usr/local/bin/virtctl
    sudo chmod +x /usr/local/bin/virtctl; }
}

# ---------------------------------------------------------------------------
# verify: capture ping + OVS flows into the two raw-output deliverables.
# Works for either endpoint type (two VMs, or a VM + a pod, or two pods) as long as both are on
# the ovs-net secondary network with 10.10.0.1 / 10.10.0.2 on their OVS interface.
verify() {
  log "Datapath verification -> ping_results.txt + verification_flows.json"
  local TS; TS=$(date -u +%FT%TZ)
  { echo "# Ping test over OVS bridge ${OVS_BRIDGE}";
    echo "# Captured (UTC): ${TS}"; echo "";
    if kc get vmi vm-a >/dev/null 2>&1; then
      # Real KubeVirt VM datapath (this is what the captured run did): vm-a self-assigns 10.10.0.1
      # on eth1 via cloud-init; give the peer pod-b its IP, then ping the VM across the bridge.
      echo "# pod-b (10.10.0.2) -> KubeVirt VM vm-a (10.10.0.1)"; echo ""
      kc exec pod-b -- ip addr add 10.10.0.2/24 dev net1 2>/dev/null || true
      kc exec pod-b -- ip link set net1 up 2>/dev/null || true
      kc exec pod-b -- ping -c 10 10.10.0.1 2>&1
    else
      # Pure pod<->pod fallback if the VM isn't up.
      echo "# pod-a (10.10.0.1) -> pod-b (10.10.0.2)"; echo ""
      kc exec pod-a -- ping -c 10 10.10.0.2 2>&1
    fi
  } | tee ping_results.txt
  log "dumping OVS flows"
  # OVS 3.x ovs-ofctl has no --format=json; capture real output and serialise it (see JSON builder
  # note in ASSUMPTIONS.md). Both OpenFlow and datapath flows are captured.
  sudo ovs-ofctl dump-flows "$OVS_BRIDGE" > /tmp/of.txt
  sudo ovs-appctl dpctl/dump-flows -m > /tmp/dp.txt
  sudo ovs-ofctl dump-ports "$OVS_BRIDGE" > /tmp/ports.txt
  python3 - "$OVS_BRIDGE" > verification_flows.json <<'PY'
import re,json,sys,datetime
br=sys.argv[1]; of=open('/tmp/of.txt').read(); dp=open('/tmp/dp.txt').read(); ports=open('/tmp/ports.txt').read()
def g(p,s):
    m=re.search(p,s); return m.group(1) if m else None
openflow=[]
for line in of.splitlines():
    if 'table=' not in line: continue
    d={k:v for k,v in re.findall(r'([a-z_]+)=([^\s,]+)', line)}
    am=re.search(r'actions=(\S+)', line); d['actions']=am.group(1) if am else None
    openflow.append(d)
dpf=[]
for line in dp.splitlines():
    if 'in_port(' not in line: continue
    dpf.append({"in_port":g(r'in_port\(([^)]+)\)',line),"eth_src":g(r'eth\(src=([0-9a-f:]+)',line),
      "eth_dst":g(r'dst=([0-9a-f:]+)\)',line),"eth_type":g(r'eth_type\((0x[0-9a-f]+)\)',line),
      "l3_l4":(re.search(r'eth_type\(0x[0-9a-f]+\),(.+?), packets:',line) or [None,None])[1] if re.search(r'eth_type\(0x[0-9a-f]+\),(.+?), packets:',line) else None,
      "packets":int(g(r'packets:(\d+)',line) or 0),"bytes":int(g(r'bytes:(\d+)',line) or 0),
      "actions":g(r'actions:(.+?), dp-extra-info',line)})
json.dump({"meta":{"bridge":br,"captured_utc":datetime.datetime.now(datetime.UTC).isoformat(),
  "note":"ovs-ofctl (OVS 3.x) has no --format=json; captured from real command output and serialised. datapath_flows carry per-flow packet/byte counters proving traversal."},
  "openflow_flows":openflow,"datapath_flows":dpf,
  "raw":{"ovs-ofctl dump-flows":of,"ovs-appctl dpctl/dump-flows -m":dp,"ovs-ofctl dump-ports":ports}},
  sys.stdout,indent=2)
PY
  log "wrote verification_flows.json ($(wc -c < verification_flows.json) bytes)"
}

main() {
  case "${1:-all}" in
    verify) verify ;;
    all)
      phase_ovs; phase_k3s; phase_cni_prereqs; phase_multus_ovscni; phase_kubevirt
      log "bootstrap complete."
      log "next: kubectl apply -f manifests.yaml   then:   ./cluster_setup.sh verify"
      ;;
    *) echo "usage: $0 [all|verify]" >&2; exit 1 ;;
  esac
}
main "${1:-all}"
