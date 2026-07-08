#!/bin/bash
# =============================================================================
# OVS DATAPATH VERIFICATION SCRIPT
# Re-runnable verification of OVS bridge connectivity and flow evidence
# =============================================================================

set -euo pipefail

# Configuration
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/output}"
OVS_BRIDGE_NAME="${OVS_BRIDGE_NAME:-ovs-br0}"
CLUSTER_TYPE="${CLUSTER_TYPE:-kind}"
CLUSTER_NAME="${CLUSTER_NAME:-kubevirt-ovs-cluster}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${GREEN}[INFO ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN ]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}==> $*${NC}"; }

mkdir -p "${OUTPUT_DIR}"

step "1/5 Checking cluster and VM status"

# Detect cluster type
if kubectl config current-context | grep -q "kind-"; then
  CLUSTER_TYPE="kind"
  CLUSTER_NAME=$(kubectl config current-context | sed 's/kind-//')
  WORKER_NODE="$(kind get nodes --name "${CLUSTER_NAME}" | grep worker | head -1 || hostname)"
elif kubectl get nodes -o wide | grep -q "k3s"; then
  CLUSTER_TYPE="k3s"
  WORKER_NODE="$(hostname)"
else
  CLUSTER_TYPE="unknown"
  WORKER_NODE="$(hostname)"
fi

log "Cluster type: ${CLUSTER_TYPE}"
log "Worker node: ${WORKER_NODE}"

# Check VMs
for VM in vm-a vm-b; do
  if ! kubectl get vmi "${VM}" &>/dev/null; then
    err "VM ${VM} not found. Deploy with: kubectl apply -f manifests.yaml"
    exit 1
  fi
  
  PHASE=$(kubectl get vmi "${VM}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  if [[ "${PHASE}" != "Running" ]]; then
    err "VM ${VM} is not Running (current: ${PHASE})"
    exit 1
  fi
  log "✔ ${VM}: ${PHASE}"
done

# Check verification pod
if ! kubectl get pod ovs-ping-pod &>/dev/null; then
  warn "Verification pod not found. Deploy with: kubectl apply -f manifests.yaml"
  SKIP_POD_PING=true
else
  POD_PHASE=$(kubectl get pod ovs-ping-pod -o jsonpath='{.status.phase}')
  if [[ "${POD_PHASE}" != "Running" ]]; then
    warn "Verification pod not Running (current: ${POD_PHASE})"
    SKIP_POD_PING=true
  else
    log "✔ ovs-ping-pod: ${POD_PHASE}"
    SKIP_POD_PING=false
  fi
fi

step "2/5 Installing classifier flow rules"

# Install per-source classifier rules (from Aditya's approach)
if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
  docker exec "${WORKER_NODE}" bash -c "
    ovs-ofctl add-flow ${OVS_BRIDGE_NAME} 'priority=100,ip,nw_src=10.10.0.10,actions=normal'
    ovs-ofctl add-flow ${OVS_BRIDGE_NAME} 'priority=100,ip,nw_src=10.10.0.11,actions=normal'
    ovs-ofctl add-flow ${OVS_BRIDGE_NAME} 'priority=100,ip,nw_src=10.10.0.20,actions=normal'
  "
else
  sudo ovs-ofctl add-flow "${OVS_BRIDGE_NAME}" 'priority=100,ip,nw_src=10.10.0.10,actions=normal'
  sudo ovs-ofctl add-flow "${OVS_BRIDGE_NAME}" 'priority=100,ip,nw_src=10.10.0.11,actions=normal'
  sudo ovs-ofctl add-flow "${OVS_BRIDGE_NAME}" 'priority=100,ip,nw_src=10.10.0.20,actions=normal'
fi

log "✔ Classifier flow rules installed"

step "3/5 Running ping tests"

PING_RESULTS="${OUTPUT_DIR}/ping_results.txt"
: > "${PING_RESULTS}"

# Pod to VM pings
if [[ "${SKIP_POD_PING}" == "false" ]]; then
  log "Testing: Pod → vm-a (10.10.0.10)"
  {
    echo "========================================" 
    echo "Test 1: ovs-ping-pod → vm-a (10.10.0.10)"
    echo "========================================"
    echo
  } >> "${PING_RESULTS}"
  
  kubectl exec ovs-ping-pod -- ping -c 5 -W 2 -I net1 10.10.0.10 >> "${PING_RESULTS}" 2>&1 || {
    echo "FAILED: No connectivity to vm-a" >> "${PING_RESULTS}"
  }
  echo >> "${PING_RESULTS}"
  
  log "Testing: Pod → vm-b (10.10.0.11)"
  {
    echo "========================================"
    echo "Test 2: ovs-ping-pod → vm-b (10.10.0.11)"
    echo "========================================"
    echo
  } >> "${PING_RESULTS}"
  
  kubectl exec ovs-ping-pod -- ping -c 5 -W 2 -I net1 10.10.0.11 >> "${PING_RESULTS}" 2>&1 || {
    echo "FAILED: No connectivity to vm-b" >> "${PING_RESULTS}"
  }
  echo >> "${PING_RESULTS}"
fi

# VM to VM pings (if virtctl available)
if command -v virtctl &>/dev/null && command -v expect &>/dev/null; then
  log "Testing: vm-a → vm-b (via virtctl console)"
  {
    echo "========================================"
    echo "Test 3: vm-a → vm-b (10.10.0.11) via console"
    echo "========================================"
    echo
  } >> "${PING_RESULTS}"
  
  expect <<'EOF' >> "${PING_RESULTS}" 2>&1 || true
set timeout 30
spawn virtctl console vm-a
expect {
  -re "(?i)login:" { 
    send "cirros\r"
    expect "assword:"
    send "gocubsgo\r"
    expect "$ "
    send "ping -c 5 -I eth1 10.10.0.11\r"
    expect "$ "
    send "exit\r"
  }
  timeout { puts "Timeout waiting for login" }
}
EOF
  echo >> "${PING_RESULTS}"
  
  log "Testing: vm-b → vm-a (via virtctl console)"
  {
    echo "========================================"
    echo "Test 4: vm-b → vm-a (10.10.0.10) via console"
    echo "========================================"
    echo
  } >> "${PING_RESULTS}"
  
  expect <<'EOF' >> "${PING_RESULTS}" 2>&1 || true
set timeout 30
spawn virtctl console vm-b
expect {
  -re "(?i)login:" {
    send "cirros\r"
    expect "assword:"
    send "gocubsgo\r"
    expect "$ "
    send "ping -c 5 -I eth1 10.10.0.10\r"
    expect "$ "
    send "exit\r"
  }
  timeout { puts "Timeout waiting for login" }
}
EOF
  echo >> "${PING_RESULTS}"
else
  warn "virtctl or expect not available, skipping VM console pings"
fi

log "✔ Ping tests complete: ${PING_RESULTS}"

step "4/5 Capturing OVS evidence"

if [[ "${CLUSTER_TYPE}" == "kind" ]]; then
  docker exec "${WORKER_NODE}" ovs-ofctl dump-flows "${OVS_BRIDGE_NAME}" > "${OUTPUT_DIR}/flows_raw.txt"
  docker exec "${WORKER_NODE}" ovs-appctl dpctl/dump-flows > "${OUTPUT_DIR}/datapath_raw.txt" 2>/dev/null || echo "N/A" > "${OUTPUT_DIR}/datapath_raw.txt"
  docker exec "${WORKER_NODE}" ovs-appctl fdb/show "${OVS_BRIDGE_NAME}" > "${OUTPUT_DIR}/fdb.txt" 2>/dev/null || echo "N/A" > "${OUTPUT_DIR}/fdb.txt"
  docker exec "${WORKER_NODE}" ovs-ofctl show "${OVS_BRIDGE_NAME}" > "${OUTPUT_DIR}/ports.txt"
else
  sudo ovs-ofctl dump-flows "${OVS_BRIDGE_NAME}" > "${OUTPUT_DIR}/flows_raw.txt"
  sudo ovs-appctl dpctl/dump-flows > "${OUTPUT_DIR}/datapath_raw.txt" 2>/dev/null || echo "N/A" > "${OUTPUT_DIR}/datapath_raw.txt"
  sudo ovs-appctl fdb/show "${OVS_BRIDGE_NAME}" > "${OUTPUT_DIR}/fdb.txt" 2>/dev/null || echo "N/A" > "${OUTPUT_DIR}/fdb.txt"
  sudo ovs-ofctl show "${OVS_BRIDGE_NAME}" > "${OUTPUT_DIR}/ports.txt"
fi

log "✔ OVS evidence captured"

step "5/5 Generating verification_flows.json"

# Use the parser from cluster_setup.sh if it exists, otherwise create inline
if [[ ! -f "${OUTPUT_DIR}/flows_parser.py" ]]; then
  cat > "${OUTPUT_DIR}/flows_parser.py" <<'EOFPARSER'
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
print(json.dumps({"flows": flows, "_meta": {"bridge": "ovs-br0"}}, indent=2))
EOFPARSER
  chmod +x "${OUTPUT_DIR}/flows_parser.py"
fi

python3 "${OUTPUT_DIR}/flows_parser.py" < "${OUTPUT_DIR}/flows_raw.txt" > "${OUTPUT_DIR}/verification_flows.json"

log "✔ verification_flows.json generated"

# Analysis
step "Verification Summary"

ZERO_LOSS=$(grep -c "0% packet loss" "${PING_RESULTS}" 2>/dev/null || echo 0)
FLOW_COUNT=$(python3 -c "import json; d=json.load(open('${OUTPUT_DIR}/verification_flows.json')); print(len(d['flows']))" 2>/dev/null || echo 0)

echo
log "Ping tests with 0% packet loss: ${ZERO_LOSS}"
log "OpenFlow rules captured: ${FLOW_COUNT}"
log "Evidence bundle: ${OUTPUT_DIR}/"
echo

if [[ ${ZERO_LOSS} -ge 2 ]]; then
  log "✅ VERIFICATION PASSED - OVS datapath is functional"
  exit 0
else
  err "❌ VERIFICATION FAILED - Insufficient successful pings"
  err "Review ${PING_RESULTS} for details"
  exit 2
fi
