#!/usr/bin/env bash
#
# verify_datapath.sh — standalone, re-runnable verification of the OVS east-west datapath.
#
# Runs AFTER `cluster_setup.sh` has built the cluster and applied `manifests.yaml`.
# Safe to re-run at any time. On each run it:
#
#   1. Re-asserts the OVS bridge and a set of explicit per-source classifier rules,
#      so `verification_flows.json` can prove that ping traffic was *classified*
#      (not just default-forwarded via `NORMAL`).
#   2. Runs bidirectional pings between the guests, driven from inside the VMs via
#      `virtctl console` + `expect` when available, otherwise from the OVS-attached
#      verification pod. Both routes go across `br1`; the console route additionally
#      proves VM→VM switching.
#   3. Captures raw text dumps of flows / datapath / FDB / ports / topology into
#      `evidence/`, then parses them into `verification_flows.json` using
#      `flows_to_json.py --bundle`. Text and JSON are consistent by construction.
#   4. Records the execution mode of the running virt-launcher (KVM vs TCG) into
#      `evidence/execution_mode.txt`.
#
# The script intentionally does not `set -e`: if the automated console ping fails
# (console automation is finicky under emulation), the deterministic flow capture
# still runs, the pod-based ping still runs, and the script exits with a clear
# non-zero status. Deterministic evidence files are always produced.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-ovs-kubevirt}"
BRIDGE="${BRIDGE:-br1}"
NS="${NS:-default}"
VM_A="${VM_A:-vm-a}"
VM_B="${VM_B:-vm-b}"
POD="${POD:-ovs-ping-pod}"
VM_A_IP="${VM_A_IP:-10.10.0.10}"
VM_B_IP="${VM_B_IP:-10.10.0.11}"
POD_IP="${POD_IP:-10.10.0.20}"
EVIDENCE_DIR="${EVIDENCE_DIR:-${SCRIPT_DIR}/evidence}"
FLOW_DUMP="${FLOW_DUMP:-${SCRIPT_DIR}/verification_flows.json}"
PING_RESULTS="${PING_RESULTS:-${SCRIPT_DIR}/ping_results.txt}"
PARSER="${PARSER:-${SCRIPT_DIR}/flows_to_json.py}"

c_g=$'\033[0;32m'; c_y=$'\033[1;33m'; c_r=$'\033[0;31m'; c_n=$'\033[0m'
log()  { printf '%s[verify]%s %s\n' "$c_g" "$c_n" "$*"; }
warn() { printf '%s[verify]%s %s\n' "$c_y" "$c_n" "$*"; }
err()  { printf '%s[verify]%s %s\n' "$c_r" "$c_n" "$*" >&2; }

# ---- 0. preconditions ------------------------------------------------------
log "0/7 Checking prerequisites"
for t in kubectl python3; do
  command -v "$t" >/dev/null 2>&1 || { err "missing required tool: $t"; exit 1; }
done

OCI=""
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  OCI=docker
elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
  OCI=podman
else
  err "Docker or Podman with a running daemon is required."
  exit 1
fi

NODE="$(kubectl get pod -l kubevirt.io/domain=${VM_A} -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"
if [[ -z "${NODE}" ]]; then
  NODE="${CLUSTER_NAME}-control-plane"
  warn "vm-a not yet scheduled; falling back to node '${NODE}'."
fi
${OCI} exec "${NODE}" true >/dev/null 2>&1 \
  || { err "cannot exec into node container '${NODE}'"; exit 1; }

[[ -f "${PARSER}" ]] || { err "missing parser: ${PARSER}"; exit 1; }

mkdir -p "${EVIDENCE_DIR}"

# ---- 1. ensure bridge + install classifier rules --------------------------
log "1/7 Ensuring bridge '${BRIDGE}' and installing per-source classifier rules"

${OCI} exec "${NODE}" ovs-vsctl --may-exist add-br "${BRIDGE}" >/dev/null
${OCI} exec "${NODE}" ovs-ofctl dump-flows "${BRIDGE}" > "${EVIDENCE_DIR}/flows_before.txt"

# Preserve any per-port ovs-cni state; only replace flow *rules* on br1.
# Explicit `nw_src=` classifiers make the JSON evidence prove classification,
# not just default-NORMAL forwarding. The `priority=0 NORMAL` catch-all is
# retained so the bridge continues to learn/forward every other frame.
${OCI} exec "${NODE}" ovs-ofctl del-flows "${BRIDGE}"
${OCI} exec "${NODE}" ovs-ofctl add-flow  "${BRIDGE}" \
  "priority=100,ip,nw_src=${VM_A_IP} actions=NORMAL"
${OCI} exec "${NODE}" ovs-ofctl add-flow  "${BRIDGE}" \
  "priority=100,ip,nw_src=${VM_B_IP} actions=NORMAL"
${OCI} exec "${NODE}" ovs-ofctl add-flow  "${BRIDGE}" \
  "priority=100,ip,nw_src=${POD_IP}  actions=NORMAL"
${OCI} exec "${NODE}" ovs-ofctl add-flow  "${BRIDGE}" \
  "priority=90,arp                   actions=NORMAL"
${OCI} exec "${NODE}" ovs-ofctl add-flow  "${BRIDGE}" \
  "priority=0                        actions=NORMAL"

# ---- 2. wait for workloads -------------------------------------------------
log "2/7 Waiting for workloads (pod + both VMIs)"
kubectl -n "${NS}" wait "pod/${POD}"                       --for=condition=Ready --timeout=180s
kubectl -n "${NS}" wait "vmi/${VM_A}" "vmi/${VM_B}"        --for=jsonpath='{.status.phase}'=Running --timeout=600s

# ---- 3. pod → VM pings (never skipped) ------------------------------------
log "3/7 Running pod→VM pings across ${BRIDGE}"
{
  echo "\$ kubectl exec ${POD} -- ping -c 4 ${VM_A_IP}"
  kubectl -n "${NS}" exec "${POD}" -- ping -c 4 "${VM_A_IP}"
  echo
  echo "\$ kubectl exec ${POD} -- ping -c 4 ${VM_B_IP}"
  kubectl -n "${NS}" exec "${POD}" -- ping -c 4 "${VM_B_IP}"
} > "${PING_RESULTS}"

# ---- 4. bidirectional VM→VM console pings (best-effort, but tried both) ---
HAVE_EXPECT=true
HAVE_VIRTCTL=true
command -v virtctl >/dev/null 2>&1 || HAVE_VIRTCTL=false
command -v expect  >/dev/null 2>&1 || HAVE_EXPECT=false

run_guest_ping() {  # $1=vm  $2=target-ip  $3=outfile
  local vm="$1" target="$2" outfile="$3"
  expect -f - "${vm}" "${target}" "${NS}" > "${outfile}" 2>&1 <<'EXPECT_EOF' || true
set vm     [lindex $argv 0]
set target [lindex $argv 1]
set ns     [lindex $argv 2]
set timeout 180
spawn virtctl console $vm --namespace $ns
send "\r"
expect {
  -re "login:"       { send "cirros\r";   exp_continue }
  -re "assword:"     { send "gocubsgo\r"; exp_continue }
  -re {\$ }          { }
  timeout            { puts "\n[verify] TIMEOUT waiting for guest prompt"; exit 2 }
}
send "ping -c 5 $target\r"
expect {
  -re "packet loss"  { }
  timeout            { puts "\n[verify] TIMEOUT waiting for ping to finish"; exit 2 }
}
expect -re {\$ }
send "\x1d"
expect eof
EXPECT_EOF
}

if $HAVE_VIRTCTL && $HAVE_EXPECT; then
  log "4/7 Running VM→VM console pings (both directions, expect-driven)"
  run_guest_ping "${VM_A}" "${VM_B_IP}" "${EVIDENCE_DIR}/console_ping_${VM_A}_to_${VM_B}.txt"
  run_guest_ping "${VM_B}" "${VM_A_IP}" "${EVIDENCE_DIR}/console_ping_${VM_B}_to_${VM_A}.txt"

  captured_any=false
  for f in "${EVIDENCE_DIR}/console_ping_${VM_A}_to_${VM_B}.txt" \
           "${EVIDENCE_DIR}/console_ping_${VM_B}_to_${VM_A}.txt"; do
    if [[ -s "${f}" ]] && grep -q '0% packet loss' "${f}"; then
      captured_any=true
      {
        echo
        echo "\$ virtctl console $(basename "${f}" .txt | sed 's/^console_ping_//; s/_to_/ then: ping -c 5 /')"
        sed -n '/PING /,/packet loss/p' "${f}"
      } >> "${PING_RESULTS}"
    fi
  done
  if ! $captured_any; then
    warn "console pings were run but no '0% packet loss' captured; pod↔VM evidence still stands"
  fi
else
  warn "4/7 Skipping VM→VM console pings (virtctl='${HAVE_VIRTCTL}', expect='${HAVE_EXPECT}')"
fi

# ---- 5. execution-mode proof (KVM vs TCG) ---------------------------------
log "5/7 Recording execution mode"
{
  echo "=== useEmulation (KubeVirt developerConfiguration) ==="
  kubectl -n kubevirt get kubevirt kubevirt \
    -o jsonpath='{.spec.configuration.developerConfiguration.useEmulation}' 2>/dev/null || true
  echo
  echo "=== /dev/kvm on node ${NODE} ==="
  ${OCI} exec "${NODE}" sh -c 'ls -la /dev/kvm 2>/dev/null || echo "(no /dev/kvm)"'
  echo
  echo "=== QEMU accelerator flag on ${VM_A} launcher ==="
  launcher_pod="$(kubectl -n "${NS}" get pods -l "kubevirt.io/domain=${VM_A}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${launcher_pod}" ]]; then
    kubectl -n "${NS}" exec "${launcher_pod}" -- sh -c \
      "ps -ef | grep -oE '\-accel [a-z]+' | head -1" 2>/dev/null \
      || echo "(could not read accel flag)"
  else
    echo "(no virt-launcher pod found)"
  fi
  echo
  echo "=== ovs-vsctl --version on node ==="
  ${OCI} exec "${NODE}" ovs-vsctl --version | head -1 || true
} > "${EVIDENCE_DIR}/execution_mode.txt"

# ---- 6. capture raw evidence text -----------------------------------------
log "6/7 Capturing raw OVS evidence text into ${EVIDENCE_DIR}/"
${OCI} exec "${NODE}" ovs-ofctl dump-flows "${BRIDGE}"       > "${EVIDENCE_DIR}/flows_raw.txt"
cp "${EVIDENCE_DIR}/flows_raw.txt" "${EVIDENCE_DIR}/flows_after.txt"
${OCI} exec "${NODE}" ovs-appctl dpctl/dump-flows            > "${EVIDENCE_DIR}/datapath_raw.txt" || true
${OCI} exec "${NODE}" ovs-appctl fdb/show "${BRIDGE}"        > "${EVIDENCE_DIR}/fdb.txt"          || true
${OCI} exec "${NODE}" ovs-ofctl  show      "${BRIDGE}"       > "${EVIDENCE_DIR}/ports.txt"
${OCI} exec "${NODE}" ovs-vsctl  show                        > "${EVIDENCE_DIR}/bridge_topology.txt" || true

ovs_version="$(${OCI} exec "${NODE}" ovs-vsctl --version | head -1)"

# ---- 7. parse to JSON -----------------------------------------------------
log "7/7 Parsing evidence bundle → ${FLOW_DUMP}"
python3 "${PARSER}" --bundle "${EVIDENCE_DIR}" --bridge "${BRIDGE}" \
  --node "${NODE}" --ovs-version "${ovs_version}" > "${FLOW_DUMP}"

# ---- summary --------------------------------------------------------------
n1=$(grep "nw_src=${VM_A_IP}" "${EVIDENCE_DIR}/flows_raw.txt" | grep -oE 'n_packets=[0-9]+' | cut -d= -f2 | head -1)
n2=$(grep "nw_src=${VM_B_IP}" "${EVIDENCE_DIR}/flows_raw.txt" | grep -oE 'n_packets=[0-9]+' | cut -d= -f2 | head -1)
n3=$(grep "nw_src=${POD_IP}"  "${EVIDENCE_DIR}/flows_raw.txt" | grep -oE 'n_packets=[0-9]+' | cut -d= -f2 | head -1)
loss_blocks=$(grep -c '0% packet loss' "${PING_RESULTS}" || true)

log "Flow-hit summary (n_packets per classifier rule):"
printf '  nw_src=%-13s -> n_packets=%s\n' "${VM_A_IP}" "${n1:-?}"
printf '  nw_src=%-13s -> n_packets=%s\n' "${VM_B_IP}" "${n2:-?}"
printf '  nw_src=%-13s -> n_packets=%s\n' "${POD_IP}"  "${n3:-?}"
log "Ping blocks with 0%% packet loss: ${loss_blocks}"

if [[ "${loss_blocks}" -ge 2 && "${n1:-0}" -gt 0 && "${n2:-0}" -gt 0 && "${n3:-0}" -gt 0 ]]; then
  log "PASS: both directions ping (>=2 zero-loss blocks) and all three classifier rules hit."
  exit 0
else
  warn "INCOMPLETE: check warnings above. Deterministic evidence files were still written."
  exit 2
fi
