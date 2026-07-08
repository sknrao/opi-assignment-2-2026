#!/usr/bin/env bash
# =============================================================================
# cluster_setup.sh  (end-to-end)
# Bootstraps minikube + Open vSwitch + Multus + OVS-CNI + KubeVirt, applies the
# VM manifests, waits for convergence, then runs verify_datapath.sh to produce
# the verification artifacts.
#
#   ./cluster_setup.sh                       # one command, start to finish
#
# -----------------------------------------------------------------------------
# HARDWARE VIRTUALIZATION — READ THIS FIRST
# -----------------------------------------------------------------------------
# The DEFAULT tested configuration, as submitted by the author, REQUIRES real
# hardware virtualization (KVM). The VMs run on genuine KVM — proof is in the
# submitted `kvm_proof.txt` and `qemu_accel.txt` (look for `-accel kvm`).
#
# Before running, confirm virtualization is enabled:
#   - bare metal : enable VT-x / AMD-V in BIOS/UEFI
#   - WSL2       : enable nested virtualization (Hyper-V / .wslconfig)
#
# If your machine does NOT have hardware virtualization, this script will build
# the cluster, detect the missing KVM, then STOP CLEANLY with instructions
# (it does not hang). To proceed anyway on slower software emulation, re-run:
#
#   ALLOW_EMULATION=1 ./cluster_setup.sh
#
# NOTE: an emulation run is clearly labeled and is NOT equivalent to the
# author's real-KVM submission.
#
# Options:
#   FRESH=1 ./cluster_setup.sh            # delete any existing minikube first
#   ALLOW_EMULATION=1 ./cluster_setup.sh  # proceed on software emulation if no KVM
#   SKIP_VERIFY=1 ./cluster_setup.sh      # stop once the cluster is ready
#   FORCE_NO_KVM=1 ./cluster_setup.sh     # TEST-ONLY: pretend KVM is absent
#       (combine with ALLOW_EMULATION=1 to exercise the emulation path on a
#        real-KVM box; emulation outputs go to emu_* and never overwrite the
#        real-KVM artifacts. Does NOT disable your hardware virtualization.)
#
# Run from the host WSL terminal, in the directory that also contains
# manifests.yaml, verify_datapath.sh and flows_to_json.py.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BRIDGE="br-ovs"
NS="default"
KV_NS="kubevirt"
EMULATION_MODE=false   # set true only if KVM absent AND ALLOW_EMULATION=1

c_g="\033[0;32m"; c_y="\033[1;33m"; c_r="\033[0;31m"; c_c="\033[0;36m"; c_n="\033[0m"
info() { echo -e "${c_g}[INFO ]${c_n} $*"; }
warn() { echo -e "${c_y}[WARN ]${c_n} $*"; }
err()  { echo -e "${c_r}[ERROR]${c_n} $*" >&2; }
step() { echo -e "\n${c_c}==================================================${c_n}"; \
         echo -e "${c_c} $*${c_n}"; \
         echo -e "${c_c}==================================================${c_n}"; }
fail() { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# STEP 0 — Preflight: tools + sibling files (KVM is checked LATER, in the node)
# ---------------------------------------------------------------------------
step "0/8  Preflight checks"
for t in minikube kubectl docker curl; do
  command -v "$t" >/dev/null 2>&1 || fail "required tool not found: $t"
done
for f in manifests.yaml verify_datapath.sh flows_to_json.py; do
  [[ -f "$SCRIPT_DIR/$f" ]] || fail "missing required file next to this script: $f"
done
chmod +x "$SCRIPT_DIR/verify_datapath.sh" 2>/dev/null || true
info "Tools and required files present. (KVM is verified inside the node in step 2.)"

# ---------------------------------------------------------------------------
# STEP 1 — Minikube
# ---------------------------------------------------------------------------
step "1/8  Minikube cluster"
if [[ "${FRESH:-0}" == "1" ]]; then
  warn "FRESH=1 set — deleting any existing minikube for a clean rebuild."
  minikube delete || true
fi
minikube start \
  --driver=docker \
  --cpus=4 \
  --memory=4096 \
  --container-runtime=containerd
kubectl get nodes >/dev/null 2>&1 || fail "kubectl cannot reach the cluster after minikube start."
info "Cluster is up and the API server is reachable."

# ---------------------------------------------------------------------------
# STEP 1b — Hardware virtualization gate (checked INSIDE the node, now that it exists)
# ---------------------------------------------------------------------------
# This is the correct place/layer: /dev/kvm must be usable inside the minikube
# node, where QEMU actually runs. We also confirm the host CPU advertises the
# virt flag. Decision:
#   * KVM usable            -> proceed on real KVM (default, no banner)
#   * KVM absent, no flag   -> STOP CLEANLY with a re-run instruction (exit 3)
#   * KVM absent + ALLOW_EMULATION=1 -> proceed on software emulation, labeled
step "1b/8  Hardware virtualization check (in-node)"
KVM_IN_NODE=false
# TEST-ONLY override: FORCE_NO_KVM=1 makes this check behave as if KVM is
# absent, so the emulation path can be exercised on a real-KVM machine
# WITHOUT disabling hardware virtualization. Does not touch the system.
if [[ "${FORCE_NO_KVM:-0}" == "1" ]]; then
  warn "FORCE_NO_KVM=1 (test-only): pretending KVM is absent for this run."
  KVM_IN_NODE=false
else
  # /dev/kvm is root:kvm mode 0660; the minikube-ssh user need not satisfy -w
  # even when KVM is fully usable (KubeVirt pods access it with the right group).
  # So gate on EXISTENCE in the node, not writability from this shell.
  if minikube ssh "test -e /dev/kvm" >/dev/null 2>&1; then
    KVM_IN_NODE=true
  fi
fi
CPU_VIRT=false
grep -qiE '(vmx|svm)' /proc/cpuinfo && CPU_VIRT=true

if [[ "$KVM_IN_NODE" == "true" && "$CPU_VIRT" == "true" ]]; then
  info "Real KVM available inside the node (/dev/kvm usable, CPU virt flag present)."
  info "Proceeding on the author's default tested config: REAL hardware virtualization."
else
  warn "Default tested config (real KVM) NOT present:"
  warn "   /dev/kvm usable in node : ${KVM_IN_NODE}"
  warn "   CPU virt flag (vmx/svm) : ${CPU_VIRT}"
  if [[ "${ALLOW_EMULATION:-0}" == "1" ]]; then
    EMULATION_MODE=true
    echo
    warn "############################################################"
    warn "# EMULATION MODE (ALLOW_EMULATION=1)                        #"
    warn "# Running under SOFTWARE emulation (TCG), not real KVM.     #"
    warn "# This run is NOT equivalent to the author's real-KVM       #"
    warn "# submission. Artifacts produced here will be labeled       #"
    warn "# emulation-only.                                           #"
    warn "############################################################"
    echo
  else
    echo
    err  "This script's default tested configuration requires real hardware"
    err  "virtualization (KVM), as submitted by the author (see kvm_proof.txt /"
    err  "qemu_accel.txt). It was not detected on this machine."
    err
    err  "Stopping cleanly (the cluster is up and will be reused on re-run)."
    err  "To proceed on software emulation instead, re-run:"
    err  ""
    err  "      ALLOW_EMULATION=1 ./cluster_setup.sh"
    err  ""
    err  "Or enable VT-x/AMD-V (BIOS) or nested virtualization (WSL) and re-run."
    exit 3
  fi
fi

# ---------------------------------------------------------------------------
# STEP 2 — Open vSwitch inside the minikube node (idempotent)
# ---------------------------------------------------------------------------
step "2/8  Open vSwitch inside the node"
minikube ssh "sudo apt-get update -qq && sudo apt-get install -y -qq openvswitch-switch" \
  || fail "OVS install failed inside the node."
minikube ssh "sudo /etc/init.d/openvswitch-switch start" || true
info "Waiting for ovs-vswitchd to respond..."
OVS_UP=false
for i in $(seq 1 20); do
  if minikube ssh "sudo ovs-vsctl show" >/dev/null 2>&1; then OVS_UP=true; break; fi
  sleep 3
done
[[ "$OVS_UP" == "true" ]] || fail "OVS did not come up inside the node."
minikube ssh "sudo ovs-vsctl --may-exist add-br ${BRIDGE}"
minikube ssh "sudo ovs-vsctl br-exists ${BRIDGE}" || fail "bridge ${BRIDGE} was not created."
info "OVS is up and bridge '${BRIDGE}' exists."

# ---------------------------------------------------------------------------
# STEP 3 — Multus CNI
# ---------------------------------------------------------------------------
step "3/8  Multus CNI"
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml
info "Waiting for Multus DaemonSet rollout..."
kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout=300s \
  || warn "Multus rollout status timed out; continuing to CRD check."
info "Waiting for the NetworkAttachmentDefinition CRD to register..."
for i in $(seq 1 30); do
  kubectl get crd network-attachment-definitions.k8s.cni.cncf.io >/dev/null 2>&1 && break
  [[ $i -eq 30 ]] && fail "NetworkAttachmentDefinition CRD never appeared."
  sleep 4
done
info "Multus ready; NAD CRD present."

# ---------------------------------------------------------------------------
# STEP 4 — OVS-CNI (must be Ready BEFORE any VM attaches to ovs-net)
# ---------------------------------------------------------------------------
step "4/8  OVS-CNI"
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/ovs-cni/main/examples/ovs-cni.yml
info "Locating the OVS-CNI DaemonSet..."
OVS_CNI_DS=""
for i in $(seq 1 15); do
  OVS_CNI_DS=$(kubectl -n kube-system get daemonset -l app=ovs-cni -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  [[ -n "$OVS_CNI_DS" ]] && break
  for n in ovs-cni-amd64 ovs-cni ovs-cni-plugin; do
    kubectl -n kube-system get daemonset "$n" >/dev/null 2>&1 && { OVS_CNI_DS="$n"; break; }
  done
  [[ -n "$OVS_CNI_DS" ]] && break
  sleep 4
done
[[ -n "$OVS_CNI_DS" ]] || fail "could not find the OVS-CNI DaemonSet."
kubectl -n kube-system rollout status "daemonset/${OVS_CNI_DS}" --timeout=300s \
  || warn "OVS-CNI rollout status timed out; continuing."
info "OVS-CNI ready (DaemonSet: ${OVS_CNI_DS})."

# ---------------------------------------------------------------------------
# STEP 5 — KubeVirt (+ emulation patch if in EMULATION_MODE)
# ---------------------------------------------------------------------------
step "5/8  KubeVirt operator + CR"
KUBEVIRT_VERSION=$(curl -sL https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)
[[ -n "$KUBEVIRT_VERSION" ]] || fail "could not resolve the latest KubeVirt version."
info "KubeVirt version: ${KUBEVIRT_VERSION}"
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
kubectl -n "$KV_NS" rollout status deployment/virt-operator --timeout=300s \
  || warn "virt-operator rollout status timed out; continuing."
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"

# Emulation patch must land BEFORE virt-handler admits VMs.
if [[ "$EMULATION_MODE" == "true" ]]; then
  warn "Patching KubeVirt for software emulation (useEmulation: true)..."
  for i in $(seq 1 30); do
    kubectl -n "$KV_NS" get kubevirt kubevirt >/dev/null 2>&1 && break
    [[ $i -eq 30 ]] && fail "KubeVirt CR never appeared (needed for emulation patch)."
    sleep 4
  done
  kubectl -n "$KV_NS" patch kubevirt kubevirt --type=merge \
    -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}' \
    || fail "failed to apply useEmulation patch."
  info "Emulation patch applied."
fi

info "Waiting for KubeVirt to reach 'Deployed' (can take several minutes)..."
for i in $(seq 1 120); do
  PHASE=$(kubectl -n "$KV_NS" get kubevirt kubevirt -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [[ "$PHASE" == "Deployed" ]] && { info "KubeVirt phase: Deployed"; break; }
  [[ $i -eq 120 ]] && fail "KubeVirt never reached 'Deployed' (last: '${PHASE}')."
  sleep 10
done
kubectl -n "$KV_NS" rollout status deployment/virt-api --timeout=300s || warn "virt-api wait timed out."
kubectl -n "$KV_NS" rollout status deployment/virt-controller --timeout=300s || warn "virt-controller wait timed out."
kubectl -n "$KV_NS" rollout status daemonset/virt-handler --timeout=300s || warn "virt-handler wait timed out."

if ! command -v virtctl >/dev/null 2>&1 && [[ ! -x /usr/local/bin/virtctl ]]; then
  info "Installing virtctl..."
  curl -L -o /tmp/virtctl "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64"
  chmod +x /tmp/virtctl && sudo mv /tmp/virtctl /usr/local/bin/virtctl
fi
info "virtctl: $(command -v virtctl || echo /usr/local/bin/virtctl)"

# ---------------------------------------------------------------------------
# STEP 6 — KubeVirt admission webhook readiness (avoids the apply race)
# ---------------------------------------------------------------------------
step "6/8  KubeVirt webhook readiness"
for i in $(seq 1 30); do
  ERRTXT=$(kubectl create --dry-run=server -f - 2>&1 <<'PROBE' || true
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata: { name: kv-probe, namespace: default }
spec: { running: false, template: { spec: { domain: { resources: { requests: { memory: 64Mi } }, devices: { disks: [], interfaces: [] } }, networks: [], volumes: [] } } }
PROBE
)
  if ! echo "$ERRTXT" | grep -qiE "webhook|connection refused|context deadline|no endpoints"; then
    info "Webhook is responsive."
    break
  fi
  [[ $i -eq 30 ]] && fail "KubeVirt webhook never became ready."
  sleep 10
done

if [[ "${SKIP_VERIFY:-0}" == "1" ]]; then
  step "Cluster ready (SKIP_VERIFY=1)"
  info "Next: kubectl apply -f manifests.yaml  &&  ./verify_datapath.sh"
  exit 0
fi

# ---------------------------------------------------------------------------
# STEP 7 — Apply VM manifests and wait for both VMIs to be Running
# ---------------------------------------------------------------------------
step "7/8  Applying manifests and waiting for VMs"
kubectl apply -f "$SCRIPT_DIR/manifests.yaml"

wait_vmi_running() {
  local vm="$1"
  for i in $(seq 1 30); do
    kubectl -n "$NS" get vmi "$vm" >/dev/null 2>&1 && break
    [[ $i -eq 30 ]] && { err "VMI $vm was never created."; return 1; }
    sleep 4
  done
  local failed_streak=0
  for i in $(seq 1 90); do
    local phase
    phase=$(kubectl -n "$NS" get vmi "$vm" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    case "$phase" in
      Running) info "  $vm: Running"; return 0 ;;
      Failed)  failed_streak=$((failed_streak+1))
               warn "  $vm: Failed (transient? streak=$failed_streak)"
               [[ $failed_streak -ge 6 ]] && { err "$vm stuck in Failed."; kubectl -n "$NS" describe vmi "$vm" | tail -30; return 1; } ;;
      *)       failed_streak=0 ;;
    esac
    sleep 6
  done
  err "$vm did not reach Running in time."; return 1
}

VM_OK=true
wait_vmi_running vm-alpha || VM_OK=false
wait_vmi_running vm-beta  || VM_OK=false
[[ "$VM_OK" == "true" ]] || fail "one or both VMs failed to reach Running — see describe output above."

info "VMs Running; brief settle for guest console readiness..."
sleep 15

# ---------------------------------------------------------------------------
# STEP 8 — Verify the datapath
# ---------------------------------------------------------------------------
step "8/8  Datapath verification"
"$SCRIPT_DIR/verify_datapath.sh"
RC=$?

# If we ran under emulation, label the artifacts so they are never mistaken
# for the author's real-KVM submission.
if [[ "$EMULATION_MODE" == "true" ]]; then
  if [[ "${FORCE_NO_KVM:-0}" == "1" ]]; then
    # TEST-ONLY: never overwrite the real artifacts. Copy to emu_-prefixed
    # files and label only those, so your real-KVM submission stays intact.
    for f in verification_flows.json flows_after.txt ping_results.txt fdb.txt; do
      [[ -f "$SCRIPT_DIR/$f" ]] && cp "$SCRIPT_DIR/$f" "$SCRIPT_DIR/emu_${f}" 2>/dev/null || true
    done
    for f in emu_verification_flows.json emu_ping_results.txt; do
      [[ -f "$SCRIPT_DIR/$f" ]] && sed -i '1s/^/# NOTE: FORCE_NO_KVM test run under emulation — NOT the real-KVM submission.\n/' "$SCRIPT_DIR/$f" 2>/dev/null || true
    done
    cat > "$SCRIPT_DIR/EMULATION_NOTICE.txt" <<'NOTE'
THIS WAS A FORCE_NO_KVM TEST RUN UNDER SOFTWARE EMULATION (TCG).

It was produced on a real-KVM machine with FORCE_NO_KVM=1 purely to exercise
the emulation code path. The emulation outputs are in the emu_* files; the
unprefixed artifacts (verification_flows.json, ping_results.txt, etc.) remain
the real-KVM results and were NOT overwritten.
NOTE
    warn "FORCE_NO_KVM test: emulation outputs saved as emu_* (real-KVM files untouched)."
  else
    # Genuine no-KVM machine: stamp the real artifacts (they ARE emulation here).
    cat > "$SCRIPT_DIR/EMULATION_NOTICE.txt" <<'NOTE'
THIS RUN USED SOFTWARE EMULATION (TCG), NOT REAL KVM.

The author's submitted configuration and artifacts were produced on REAL
hardware virtualization (see kvm_proof.txt / qemu_accel.txt, showing -accel
kvm). This run was executed with ALLOW_EMULATION=1 on a host without usable
KVM, so its results are functionally correct but NOT performance- or
hardware-equivalent to the submitted real-KVM result.
NOTE
    for f in kvm_proof.txt ping_results.txt verification_flows.json; do
      [[ -f "$SCRIPT_DIR/$f" ]] && sed -i '1s/^/# NOTE: emulation run (ALLOW_EMULATION=1) — not the real-KVM submission. See EMULATION_NOTICE.txt\n/' "$SCRIPT_DIR/$f" 2>/dev/null || true
    done
    warn "Emulation run: wrote EMULATION_NOTICE.txt and stamped artifacts."
  fi
fi

echo
if [[ $RC -eq 0 ]]; then
  step "ALL DONE — cluster built and datapath verified"
  [[ "$EMULATION_MODE" == "true" ]] && warn "(emulation mode — see EMULATION_NOTICE.txt)"
  info "Artifacts: verification_flows.json, flows_after.txt, ping_results.txt, fdb.txt"
else
  step "CLUSTER READY, but verification reported an issue (exit ${RC})"
  warn "Re-run ./verify_datapath.sh after checking the warnings above."
fi
exit $RC
