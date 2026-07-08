#!/usr/bin/env bash
# =============================================================================
# verify_datapath.sh
# One-command, reproducible verification of the OVS east-west datapath.
#
# Run AFTER cluster_setup.sh has built the cluster and `kubectl apply -f
# manifests.yaml` has created the VMs. This script is idempotent and safe to
# re-run: it re-asserts the OVS flow rules, drives a bidirectional guest ping
# (vm-alpha <-> vm-beta over the OVS-only 192.168.100.0/24 subnet), and
# regenerates the machine-readable flow evidence.
#
# It intentionally does NOT use `set -e`: if the automated console ping fails
# (console automation can be finicky), the deterministic flow capture still
# runs and the script prints a clear manual fallback rather than aborting.
#
# Scope: this verifies the software control/data path only (real KVM, real
# OVS). It does not and cannot verify BlueField hardware offload.
# =============================================================================
set -uo pipefail

# ---- config (matches your setup) -------------------------------------------
NODE="minikube"            # the minikube node is a docker container of this name
BRIDGE="br-ovs"
NS="default"
VM1="vm-alpha"; IP1="192.168.100.1"
VM2="vm-beta";  IP2="192.168.100.2"
PARSER="./flows_to_json.py"

# ---- pretty logging --------------------------------------------------------
c_g="\033[0;32m"; c_y="\033[1;33m"; c_r="\033[0;31m"; c_n="\033[0m"
log()  { echo -e "${c_g}[verify]${c_n} $*"; }
warn() { echo -e "${c_y}[verify]${c_n} $*"; }
err()  { echo -e "${c_r}[verify]${c_n} $*" >&2; }

# ---- 0. preconditions ------------------------------------------------------
log "0/6  Checking prerequisites"
for t in kubectl docker virtctl python3; do
  command -v "$t" >/dev/null 2>&1 || { err "missing required tool: $t"; exit 1; }
done
if ! docker exec "$NODE" true >/dev/null 2>&1; then
  err "cannot exec into node container '$NODE'. Is minikube running?  (minikube status)"
  exit 1
fi
if [[ ! -f "$PARSER" ]]; then
  err "parser not found at $PARSER — keep flows_to_json.py in this directory."
  exit 1
fi
HAVE_EXPECT=true
command -v expect >/dev/null 2>&1 || { HAVE_EXPECT=false; warn "'expect' not installed — will skip automated ping (install: sudo apt-get install -y expect)"; }

# ---- 1. ensure OVS + bridge ------------------------------------------------
log "1/6  Ensuring Open vSwitch is up and '$BRIDGE' exists"
docker exec "$NODE" bash -c 'ovs-vsctl show >/dev/null 2>&1 || /etc/init.d/openvswitch-switch start' >/dev/null 2>&1 || true
docker exec "$NODE" ovs-vsctl --may-exist add-br "$BRIDGE"
docker exec "$NODE" ovs-vsctl show >/dev/null || { err "OVS not responding in node"; exit 1; }

# ---- 2. (re)install the classifier flow rules (resets counters to 0) -------
log "2/6  Installing flow rules on '$BRIDGE' (counters reset to 0)"
docker exec "$NODE" ovs-ofctl del-flows "$BRIDGE"
docker exec "$NODE" ovs-ofctl add-flow "$BRIDGE" "priority=100,ip,nw_src=${IP1},actions=NORMAL"
docker exec "$NODE" ovs-ofctl add-flow "$BRIDGE" "priority=100,ip,nw_src=${IP2},actions=NORMAL"
docker exec "$NODE" ovs-ofctl add-flow "$BRIDGE" "priority=90,arp,actions=NORMAL"
docker exec "$NODE" ovs-ofctl add-flow "$BRIDGE" "priority=0,actions=NORMAL"

# ---- 3. wait for both VMs to be Running ------------------------------------
log "3/6  Waiting for VMIs to reach Running"
for vm in "$VM1" "$VM2"; do
  for i in $(seq 1 30); do
    phase=$(kubectl -n "$NS" get vmi "$vm" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [[ "$phase" == "Running" ]] && { log "  $vm: Running"; break; }
    [[ $i -eq 30 ]] && { warn "  $vm not Running (phase='$phase') — pings may fail"; }
    sleep 4
  done
done

# ---- 4. bidirectional guest ping (automated via expect) --------------------
# eth1 IPs are assigned by cloud-init (see manifests.yaml). If a VM was started
# from the pre-cloud-init manifest, restart it once:  virtctl restart <vm>
run_guest_ping() {   # $1=vm  $2=target-ip  $3=outfile
  local vm="$1" target="$2" outfile="$3"
  expect -f - "$vm" "$target" "$NS" > "$outfile" 2>&1 <<'EXPECT_EOF'
set vm     [lindex $argv 0]
set target [lindex $argv 1]
set ns     [lindex $argv 2]
set timeout 150
spawn virtctl console $vm --namespace $ns
send "\r"
expect {
  -re "login:"   { send "cirros\r";   exp_continue }
  -re "assword:" { send "gocubsgo\r"; exp_continue }
  -re {\$ }      { }
  timeout        { puts "\n[verify] TIMEOUT waiting for guest prompt"; exit 2 }
}
send "ping -c 5 $target\r"
expect {
  -re "packet loss" { }
  timeout           { puts "\n[verify] TIMEOUT waiting for ping to finish"; exit 2 }
}
expect -re {\$ }
send "\x1d"
expect eof
EXPECT_EOF
}

PING_OK=true
if [[ "$HAVE_EXPECT" == "true" ]]; then
  log "4/6  Running guest pings (both directions)"
  log "  $VM1 -> $VM2 ($IP2)"
  run_guest_ping "$VM1" "$IP2" alpha_to_beta_ping.txt
  grep -q "0% packet loss" alpha_to_beta_ping.txt || { PING_OK=false; warn "  $VM1 -> $VM2 ping did not report 0% loss"; }
  log "  $VM2 -> $VM1 ($IP1)"
  run_guest_ping "$VM2" "$IP1" beta_to_alpha_ping.txt
  grep -q "0% packet loss" beta_to_alpha_ping.txt || { PING_OK=false; warn "  $VM2 -> $VM1 ping did not report 0% loss"; }

  # assemble the labelled deliverable
  {
    echo "============================================================================="
    echo "ping_results.txt  -  east-west ICMP over the OVS bridge ($BRIDGE)"
    echo "  vm-alpha eth1 = $IP1/24   |   vm-beta eth1 = $IP2/24"
    echo "  192.168.100.0/24 exists only on eth1 and has no route except through $BRIDGE,"
    echo "  so all traffic below necessarily traverses OVS. Pings run inside the guests."
    echo "============================================================================="
    echo; echo "----- DIRECTION 1:  $VM1 ($IP1) -> $VM2 ($IP2)  [from $VM1 console] -----"; echo
    cat alpha_to_beta_ping.txt
    echo; echo "----- DIRECTION 2:  $VM2 ($IP2) -> $VM1 ($IP1)  [from $VM2 console] -----"; echo
    cat beta_to_alpha_ping.txt
  } > ping_results.txt
  log "  wrote ping_results.txt (+ per-direction transcripts)"
else
  warn "4/6  Skipping automated ping (no 'expect'). Run manually, then re-run this script:"
  warn "     virtctl console $VM1   ->   ping -c 5 $IP2   (Ctrl+] to exit)"
  warn "     virtctl console $VM2   ->   ping -c 5 $IP1   (Ctrl+] to exit)"
  PING_OK=false
fi

# ---- 5. capture flows + parse to JSON (the machine-readable evidence) ------
log "5/6  Capturing OVS flows and parsing to JSON"
docker exec "$NODE" ovs-ofctl dump-flows "$BRIDGE" | tee flows_after.txt >/dev/null
python3 "$PARSER" < flows_after.txt > verification_flows.json
docker exec "$NODE" ovs-appctl fdb/show "$BRIDGE" | tee fdb.txt >/dev/null || true
log "  wrote flows_after.txt, verification_flows.json, fdb.txt"

# ---- 6. summary: were the classifier rules actually hit? -------------------
log "6/6  Flow-hit summary (n_packets per classifier rule)"
n1=$(grep "nw_src=${IP1}" flows_after.txt | grep -oE 'n_packets=[0-9]+' | cut -d= -f2 | head -1)
n2=$(grep "nw_src=${IP2}" flows_after.txt | grep -oE 'n_packets=[0-9]+' | cut -d= -f2 | head -1)
echo "    nw_src=${IP1}  ->  n_packets=${n1:-?}"
echo "    nw_src=${IP2}  ->  n_packets=${n2:-?}"
echo
if [[ "$PING_OK" == "true" && "${n1:-0}" -gt 0 && "${n2:-0}" -gt 0 ]]; then
  log "PASS: both directions pinged (0% loss) and both classifier rules were hit."
  echo "      (Each rule typically shows ~10 = 5 echo-request + 5 echo-reply across both runs.)"
  exit 0
else
  warn "INCOMPLETE: check the warnings above. Deterministic flow files were still written."
  warn "If n_packets are 0, the ping did not traverse OVS — verify eth1 IPs are set"
  warn "(cloud-init assigns them; a VM started from the old manifest needs: virtctl restart <vm>)."
  exit 2
fi
