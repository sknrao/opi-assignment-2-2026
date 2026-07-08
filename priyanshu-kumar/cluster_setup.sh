#!/usr/bin/env bash

# cluster_setup.sh - OPI Assignment 2: Cloud-Native OVS Datapath Challenge

# This script does the whole assignment in one run: it creates a local Kubernetes cluster, installs Open vSwitch (bridge br1) plus Multus, OVS-CNI and KubeVirt (all pinned versions), starts two CirrOS virtual machines connected to the bridge, pings vm1 -> vm2 on both OVS networks (flat and VLAN 100), saves all the proof files, and finally runs a set of PASS/FAIL checks. If any step or check fails, the script stops with a non-zero exit code.

# Usage:
#   ./cluster_setup.sh              # full setup + verification
#   CLEANUP=1 ./cluster_setup.sh    # delete the cluster and exit
# shellcheck disable=SC2016
set -euo pipefail

# Everything below is wrapped in one { } block. This makes bash read the whole file into memory before running it, so saving an edit to this file while it is already running cannot break the running copy.

{

KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5}"
MULTUS_VERSION="${MULTUS_VERSION:-v4.3.0}"
OVS_CNI_VERSION="${OVS_CNI_VERSION:-v0.39.0}"
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.8.4}"

CLUSTER_NAME="${CLUSTER_NAME:-ovs-datapath}"
BR="br1"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVIDENCE_DIR="${REPO_DIR}/evidence"

log()  { printf '\n\033[1;34m[%s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m  ✘ FATAL: %s\033[0m\n' "$*" >&2; exit 1; }
node() { kind get nodes --name "${CLUSTER_NAME}" | head -1; }
node_exec() { docker exec "$(node)" "$@"; }

FAIL=0
gate() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "PASS: ${desc}"; else
    printf '\033[1;31m  ✘ FAIL: %s\033[0m\n' "${desc}"; FAIL=1; fi
}

# Check the machine has everything this script needs (Linux amd64, a running Docker daemon, and all required command-line tools). Exit early with a clear message if anything is missing - nothing is installed or changed here.
check_prereqs() {
  log "Checking prerequisites"
  [[ "$(uname -sm)" == "Linux x86_64" ]] || die "Linux amd64 required (found $(uname -sm))"
  for bin in docker kind kubectl jq curl virtctl python3; do
    command -v "$bin" >/dev/null || die "'$bin' not found in PATH"
  done
  python3 -c 'import pexpect' 2>/dev/null || die "python3-pexpect missing (drives the VM console); try: apt install python3-pexpect"
  docker info >/dev/null 2>&1 || die "docker daemon not reachable"
  ok "linux/amd64, docker, kind, kubectl, virtctl, jq, python3-pexpect present"
}

# Delete any old cluster, then create a fresh single-node Kubernetes cluster with kind (Kubernetes-in-Docker) from the pinned node image.
create_cluster() {
  log "Creating kind cluster '${CLUSTER_NAME}' (pinned node image)"
  kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true
  kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_NODE_IMAGE}" --wait 120s
  kubectl wait --for=condition=Ready node --all --timeout=120s
  ok "node Ready: $(kubectl get nodes -o name)"
}

# Install Open vSwitch (and tcpdump, used later for the packet capture)inside the kind node, create bridge br1, and confirm the JSON flow-dump pipeline works. Note: no released ovs-ofctl has '--format=json'; ovs-flowviz is the official OVS tool for JSON flow dumps (see README).
install_ovs() {
  log "Installing Open vSwitch + bridge '${BR}' inside the node"
  node_exec bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openvswitch-switch tcpdump >/dev/null'
  node_exec systemctl enable --now openvswitch-switch
  node_exec bash -c 'for i in $(seq 30); do ovs-vsctl show >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1' \
    || die "ovs-vswitchd did not become ready"
  node_exec ovs-vsctl --may-exist add-br "${BR}"
  ok "OVS running ($(node_exec ovs-vsctl --version | head -1)); bridge '${BR}' exists"
  node_exec bash -c "ovs-ofctl dump-flows ${BR} | ovs-flowviz openflow json" | jq -e . >/dev/null \
    || die "'ovs-ofctl dump-flows | ovs-flowviz openflow json' did not produce valid JSON"
  ok "JSON flow-dump pipeline works (ovs-ofctl | ovs-flowviz)"
}

# Deploy Multus (adds extra network interfaces to pods/VMs) and OVS-CNI(plugs those interfaces into the OVS bridge), both image-pinned. Wait until both daemonsets are ready and the OVS-CNI marker advertises br1 as a node resource - VMs cannot schedule onto the bridge before that.
install_cni() {
  log "Deploying Multus ${MULTUS_VERSION} + OVS-CNI ${OVS_CNI_VERSION} (images pinned)"
  curl -fsSL "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${MULTUS_VERSION}/deployments/multus-daemonset-thick.yml" \
    | sed "s|multus-cni:snapshot-thick|multus-cni:${MULTUS_VERSION}-thick|g" | kubectl apply -f -
  curl -fsSL "https://raw.githubusercontent.com/k8snetworkplumbingwg/ovs-cni/${OVS_CNI_VERSION}/examples/ovs-cni.yml" \
    | sed "s|ovs-cni-plugin:latest|ovs-cni-plugin:${OVS_CNI_VERSION}|g" | kubectl apply -f -
  local ds
  for ds in multus ovs-cni; do
    kubectl -n kube-system rollout status "$(kubectl -n kube-system get ds -l app=$ds -o name)" --timeout=300s
  done
  kubectl wait node --all --timeout=120s \
    --for=jsonpath="{.status.capacity.ovs-cni\.network\.kubevirt\.io/${BR}}" \
    || die "OVS-CNI marker never advertised '${BR}'"
  ok "Multus + OVS-CNI rolled out; marker advertises 'ovs-cni.network.kubevirt.io/${BR}'"
}

# Deploy KubeVirt (runs real VMs inside Kubernetes). Use hardware virtualization if the node has /dev/kvm; otherwise fall back to software emulation via the supported useEmulation flag.
install_kubevirt() {
  log "Deploying KubeVirt ${KUBEVIRT_VERSION}"
  kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
  kubectl -n kubevirt rollout status deploy/virt-operator --timeout=300s
  kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"
  if node_exec test -e /dev/kvm; then
    ok "/dev/kvm present → hardware virtualization (KVM)"
  else
    log "/dev/kvm absent → enabling KubeVirt useEmulation"
    kubectl -n kubevirt patch kubevirt kubevirt --type=merge \
      -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
  fi
  kubectl -n kubevirt wait kv/kubevirt --for=condition=Available --timeout=600s
  ok "KubeVirt Available"
}

# Apply manifests.yaml (two OVS networks + vm1 + vm2) and wait until both virtual machines are created and fully booted.
deploy_vms() {
  log "Applying manifests.yaml (NADs ovs-net + ovs-net-vlan100, vm1 + vm2)"
  kubectl apply -f "${REPO_DIR}/manifests.yaml"
  kubectl wait --for=create vmi/vm1 vmi/vm2 --timeout=180s
  kubectl wait vmi vm1 vm2 --for=condition=Ready --timeout=600s
  ok "vm1 + vm2 Running"
}

# Verify each VM is really attached to the bridge, at two layers - Kubernetes (the multus network-status annotation lists both OVS networks) and OVS itself (4 VM ports on br1, 2 of them tagged VLAN 100).
verify_vm_attachment() {
  log "Attachment gates: multus network-status + OVS ports on ${BR}"
  local vm net status
  for vm in vm1 vm2; do
    status="$(kubectl get pod -l "vm.kubevirt.io/name=${vm}" \
      -o jsonpath='{.items[0].metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}')"
    for net in ovs-net ovs-net-vlan100; do
      gate "$vm network-status includes default/${net}" \
        jq -e ".[] | select(.name == \"default/${net}\")" <<<"$status"
    done
  done
  gate "${BR} carries ≥4 VM ports" \
    bash -c "[ \"\$(docker exec \"$(node)\" ovs-vsctl list-ports ${BR} | grep -c .)\" -ge 4 ]"
  gate "2 ports have OVS access tag=100 (VLAN NAD honored)" \
    bash -c "[ \"\$(docker exec \"$(node)\" ovs-vsctl --format=csv --no-headings --columns=tag list Port | grep -cx 100)\" -eq 2 ]"
  [[ $FAIL -eq 0 ]] || die "VM attachment gates FAILED"
  log "VM ATTACHMENT GATES PASS"
}

console_ping() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import sys, time, pexpect
vm, target, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
child = pexpect.spawn(f"virtctl console {vm}", encoding="utf-8", timeout=120)
child.logfile_read = sys.stdout
child.expect("Successfully connected")
for attempt in range(30):
    child.sendline("")
    idx = child.expect([r"login:", r"\$ $", pexpect.TIMEOUT], timeout=10)
    if idx == 0:
        child.sendline("cirros"); child.expect("Password:")
        child.sendline("gocubsgo"); child.expect(r"\$ ")
        break
    if idx == 1:
        break
else:
    sys.exit("ERROR: never reached a CirrOS login prompt")
child.sendline(f"ping -c {count} {target}")
child.expect(r"packet loss", timeout=count + 60)
child.expect(r"\$ ")
child.sendline("exit"); time.sleep(1); child.close()
PYEOF
}

save_ping() {
  { printf '# Generated by cluster_setup.sh on %s\n# %s\n' "$TS" "$3"
    sed -n '/^PING /,/^round-trip/p' "$1" | tr -d '\r'; } > "$2"
}

# The datapath proof: snapshot the flow counters, ping vm1 → vm2 on both OVS networks (recording a tcpdump pcap on vm1's bridge port during the flat-network ping), save every piece of evidence, then judge the result with PASS/FAIL gates. The script exits non-zero if any gate fails.
verify_datapath() {
  log "Datapath verification: vm1 → vm2 over ${BR}"
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  node_exec ovs-ofctl dump-flows "${BR}" > "${EVIDENCE_DIR}/flows_before.txt"
  node_exec ovs-ofctl dump-ports "${BR}" > "${EVIDENCE_DIR}/port_stats_before.txt"

  log "Warm-up ping (FDB population for port mapping)"
  console_ping vm1 10.10.0.2 2 > /dev/null
  local ofport port
  ofport="$(node_exec ovs-appctl fdb/show "${BR}" | awk '$3 == "02:00:00:00:00:01" {print $1; exit}')"
  port="$(node_exec ovs-ofctl show "${BR}" | awk -F'[()]' -v p="$ofport" '$1 == " "p {print $2; exit}')"
  [[ -n "$port" ]] || die "could not map vm1 eth1 to its OVS port"
  ok "vm1 eth1 is OVS port ${ofport} (${port}); starting tcpdump on it"
  node_exec bash -c "rm -f /tmp/vm1.pcap && nohup tcpdump -i '${port}' -w /tmp/vm1.pcap icmp >/dev/null 2>&1 &"
  node_exec bash -c 'for i in $(seq 10); do [ -e /tmp/vm1.pcap ] && exit 0; sleep 1; done; exit 1' \
    || die "tcpdump never started"

  console_ping vm1 10.10.0.2 20 | tee "${EVIDENCE_DIR}/console_vm1.log"
  node_exec ovs-appctl dpctl/dump-flows -m > "${EVIDENCE_DIR}/dpctl_microflows.txt" 2>&1

  node_exec bash -c 'pkill -x tcpdump 2>/dev/null; for i in $(seq 10); do pgrep -x tcpdump >/dev/null || exit 0; sleep 1; done' || true
  node_exec cat /tmp/vm1.pcap > "${EVIDENCE_DIR}/vm1_eth1.pcap"
  log "VLAN-100 ping vm1 → vm2 over eth2"
  console_ping vm1 10.10.100.2 20 | tee "${EVIDENCE_DIR}/console_vm1_vlan100.log"

  save_ping "${EVIDENCE_DIR}/console_vm1.log" "${REPO_DIR}/ping_results.txt" \
    'ping -c 20 10.10.0.2 inside vm1 via "virtctl console": eth1 10.10.0.1 -> vm2 eth1 10.10.0.2 on br1'
  save_ping "${EVIDENCE_DIR}/console_vm1_vlan100.log" "${EVIDENCE_DIR}/ping_vlan100.txt" \
    'ping -c 20 10.10.100.2 inside vm1: eth2 (VLAN 100 access ports) on br1'
  node_exec bash -c "ovs-ofctl dump-flows ${BR} | ovs-flowviz openflow json" > "${REPO_DIR}/verification_flows.json"
  jq -e . "${REPO_DIR}/verification_flows.json" >/dev/null || die "verification_flows.json is not valid JSON"
  printf 'command: docker exec %s bash -c "ovs-ofctl dump-flows %s | ovs-flowviz openflow json"\ntimestamp: %s\n' \
    "$(node)" "${BR}" "$TS" > "${EVIDENCE_DIR}/verification_flows.provenance.txt"
  node_exec ovs-ofctl dump-flows "${BR}" > "${EVIDENCE_DIR}/flows_after.txt"
  node_exec ovs-ofctl dump-ports "${BR}" > "${EVIDENCE_DIR}/port_stats_after.txt"
  node_exec ovs-appctl fdb/show "${BR}" > "${EVIDENCE_DIR}/fdb.txt"

  log "Datapath PASS/FAIL gates"
  gate "ping vm1→vm2: 0% packet loss" grep -q " 0% packet loss" "${REPO_DIR}/ping_results.txt"

  local before after delta
  before="$(grep -o 'n_packets=[0-9]*' "${EVIDENCE_DIR}/flows_before.txt" | head -1 | cut -d= -f2)"
  after="$(grep -o 'n_packets=[0-9]*' "${EVIDENCE_DIR}/flows_after.txt" | head -1 | cut -d= -f2)"
  delta=$(( after - before ))
  gate "NORMAL flow n_packets delta ≥ 40 (got ${delta})" test "$delta" -ge 40

  gate "FDB contains vm1 MAC 02:00:00:00:00:01" grep -qi "02:00:00:00:00:01" "${EVIDENCE_DIR}/fdb.txt"
  gate "FDB contains vm2 MAC 02:00:00:00:00:02" grep -qi "02:00:00:00:00:02" "${EVIDENCE_DIR}/fdb.txt"


  megaflow_pkts() { grep "eth(src=$1,dst=$2)" "${EVIDENCE_DIR}/dpctl_microflows.txt" \
    | grep 'eth_type(0x0800)' | grep -o 'packets:[0-9]*' | cut -d: -f2 | head -1; }
  local fwd rev
  fwd="$(megaflow_pkts 02:00:00:00:00:01 02:00:00:00:00:02)"; fwd="${fwd:-0}"
  rev="$(megaflow_pkts 02:00:00:00:00:02 02:00:00:00:00:01)"; rev="${rev:-0}"
  gate "datapath megaflow vm1→vm2 (pinned MACs, IPv4, ${fwd} pkts ≥ 15)" test "$fwd" -ge 15
  gate "datapath megaflow vm2→vm1 (pinned MACs, IPv4, ${rev} pkts ≥ 15)" test "$rev" -ge 15

  local req rep
  req="$(node_exec tcpdump -nn -r /tmp/vm1.pcap 2>/dev/null | grep -c 'ICMP echo request' || true)"
  rep="$(node_exec tcpdump -nn -r /tmp/vm1.pcap 2>/dev/null | grep -c 'ICMP echo reply' || true)"
  gate "pcap on vm1 port: ≥ 15 ICMP echo requests (got ${req})" test "$req" -ge 15
  gate "pcap on vm1 port: ≥ 15 ICMP echo replies (got ${rep})"  test "$rep" -ge 15

  gate "VLAN-100 ping vm1→vm2: 0% packet loss" grep -q " 0% packet loss" "${EVIDENCE_DIR}/ping_vlan100.txt"
  gate "FDB has vm1 eth2 MAC 02:00:00:00:01:01 on VLAN 100" \
    bash -c "awk '\$2 == 100 && \$3 == \"02:00:00:00:01:01\"' '${EVIDENCE_DIR}/fdb.txt' | grep -q ."
  gate "FDB has vm2 eth2 MAC 02:00:00:00:01:02 on VLAN 100" \
    bash -c "awk '\$2 == 100 && \$3 == \"02:00:00:00:01:02\"' '${EVIDENCE_DIR}/fdb.txt' | grep -q ."

  [[ $FAIL -eq 0 ]] || die "one or more datapath gates FAILED"
  log "ALL DATAPATH GATES PASS"
}

if [[ "${CLEANUP:-0}" == "1" ]]; then
  log "CLEANUP=1 → deleting kind cluster '${CLUSTER_NAME}'"
  kind delete cluster --name "${CLUSTER_NAME}" || true
  exit 0
fi

mkdir -p "${EVIDENCE_DIR}"
exec > >(tee "${EVIDENCE_DIR}/setup_run.log") 2>&1
log "cluster_setup.sh starting (cluster=${CLUSTER_NAME}, bridge=${BR})"

check_prereqs
create_cluster
install_ovs
install_cni
install_kubevirt
deploy_vms
verify_vm_attachment
verify_datapath

log "COMPLETE: cluster + OVS + VMs deployed, datapath verified. Artifacts: verification_flows.json, ping_results.txt, evidence/"
exit 0
}
