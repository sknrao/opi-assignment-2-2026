#!/usr/bin/env bash
#
# Hands-On Assignment 2: Cloud-Native OVS Datapath Challenge
#
# This script deliberately shows its work. Each stage proves one layer before
# moving to the next, which makes a failure useful instead of mysterious.
#
# A successful run leaves two pieces of evidence beside this script:
#   ping_results.txt          - the guest connectivity test
#   verification_flows.json   - the OVS rules and their packet counters
# The cluster is intentionally left running so those results can be inspected.

# Fail early on errors, unset variables, and broken pipelines. The ERR trap
# below then prints the state that is usually most useful for troubleshooting.
set -Eeuo pipefail

# These names and addresses are shared by setup, testing, and verification.
# Component versions are pinned so a future rerun does not silently assemble a
# different stack.
readonly CLUSTER_NAME="${CLUSTER_NAME:-ovs-datapath}"
readonly NODE_NAME="${CLUSTER_NAME}-control-plane"
readonly LAB_NAMESPACE="ovs-lab"
readonly OVS_BRIDGE="br-ovs"
readonly VM_IP="192.168.100.10"
readonly PEER_IP="192.168.100.20"
readonly KIND_VERSION="v0.31.0"
readonly KIND_NODE_IMAGE="kindest/node:v1.35.0"
readonly KUBEVIRT_VERSION="v1.8.2"
readonly CNAO_VERSION="v0.102.0"
readonly FLOW_COOKIE="0xc10d2026"
readonly ARM_TCG_CPU_MODEL="cortex-a57"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly MANIFESTS_FILE="${SCRIPT_DIR}/manifests.yaml"
readonly PING_OUTPUT="${SCRIPT_DIR}/ping_results.txt"
readonly FLOW_OUTPUT="${SCRIPT_DIR}/verification_flows.json"

# Runtime state is kept separate from the fixed lab definition above. In
# particular, DATAPATH_TYPE records whether OVS could use the kernel datapath
# or had to fall back to its userspace implementation.
WORK_DIR=""
KIND_BIN=""
DATAPATH_TYPE="unknown"
USE_EMULATION="false"
HOST_PLATFORM=""
CURRENT_STAGE="startup"

stage() {
  CURRENT_STAGE="$1"
  printf '\n[%s] %s\n' "$(date +'%H:%M:%S')" "$CURRENT_STAGE"
}

note() {
  printf '  -> %s\n' "$*"
}

die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
}

show_diagnostics() {
  local exit_code=$?
  trap - ERR
  set +e

  # Do not tear down the lab on failure. A half-built cluster is often the
  # clearest explanation of which layer did not become ready.
  printf '\nFAILED during stage: %s (exit code %s)\n' \
    "${CURRENT_STAGE}" "${exit_code}" >&2
  printf 'The cluster has been left running for inspection.\n' >&2

  if command -v kubectl >/dev/null 2>&1; then
    printf '\n--- Kubernetes nodes and pods ---\n' >&2
    kubectl get nodes -o wide >&2
    kubectl get pods -A -o wide >&2

    printf '\n--- Recent events ---\n' >&2
    kubectl get events -A --sort-by='.lastTimestamp' 2>/dev/null | tail -n 50 >&2

    printf '\n--- VM state ---\n' >&2
    kubectl -n "${LAB_NAMESPACE}" get vm,vmi 2>/dev/null >&2

    printf '\n--- NetworkAddonsConfig state ---\n' >&2
    kubectl get networkaddonsconfig cluster -o yaml 2>/dev/null | tail -n 80 >&2
  fi

  if command -v docker >/dev/null 2>&1 &&
    docker inspect "${NODE_NAME}" >/dev/null 2>&1; then
    printf '\n--- OVS state inside the KinD node ---\n' >&2
    docker exec "${NODE_NAME}" ovs-vsctl show >&2
    docker exec "${NODE_NAME}" ovs-ofctl -O OpenFlow13 show "${OVS_BRIDGE}" >&2
    docker exec "${NODE_NAME}" ovs-ofctl -O OpenFlow13 dump-flows "${OVS_BRIDGE}" >&2
  fi

  printf '\nUseful next commands:\n' >&2
  printf '  kubectl get pods -A\n' >&2
  printf '  kubectl -n %s describe vmi ovs-vm\n' "${LAB_NAMESPACE}" >&2
  printf '  docker exec %s ovs-vsctl show\n' "${NODE_NAME}" >&2
  exit "${exit_code}"
}

trap cleanup EXIT
trap show_diagnostics ERR

download() {
  local url="$1"
  local destination="$2"
  curl --fail --location --silent --show-error \
    --retry 3 --retry-delay 2 \
    "${url}" --output "${destination}"
}

wait_for_crd() {
  local crd="$1"
  local attempt
  for attempt in {1..30}; do
    if kubectl wait --for=condition=Established \
      "crd/${crd}" --timeout=10s 2>/dev/null; then
      return
    fi
    sleep 2
  done
  die "CRD ${crd} did not become Established."
}

wait_for_deployment() {
  local namespace="$1"
  local deployment="$2"
  kubectl -n "${namespace}" rollout status \
    "deployment/${deployment}" --timeout=300s
}

render_manifest_phase() {
  local phase="$1"

  # kubectl resolves every resource type before applying a label selector.
  # That is a problem during bootstrap because the NAD CRD does not exist until
  # CNAO finishes. This small POSIX-awk splitter sends only the requested YAML
  # documents to kubectl, while manifests.yaml remains one valid submission.
  awk -v phase="${phase}" '
    function emit_document() {
      if (document ~ ("assignment.kubevirt.io/phase: " phase "([\n]|$)")) {
        printf "%s---\n", document
      }
      document = ""
    }
    /^---[[:space:]]*$/ {
      emit_document()
      next
    }
    {
      document = document $0 ORS
    }
    END {
      emit_document()
    }
  ' "${MANIFESTS_FILE}"
}

apply_manifest_phase() {
  render_manifest_phase "$1" | kubectl apply -f -
}

detect_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"

  case "${arch}" in
    x86_64 | amd64) arch="amd64" ;;
    arm64 | aarch64) arch="arm64" ;;
    *) die "Unsupported CPU architecture: ${arch}" ;;
  esac

  case "${os}" in
    darwin | linux) ;;
    *) die "This script supports macOS and Linux; detected ${os}." ;;
  esac

  printf '%s/%s' "${os}" "${arch}"
}

prepare_kind() {
  local platform="$1"
  local os="${platform%/*}"
  local arch="${platform#*/}"

  if command -v kind >/dev/null 2>&1 &&
    [[ "$(kind version 2>/dev/null)" == *"${KIND_VERSION}"* ]]; then
    KIND_BIN="$(command -v kind)"
    note "Using installed $(kind version)."
    return
  fi

  KIND_BIN="${WORK_DIR}/kind"
  note "Downloading KinD ${KIND_VERSION} for ${os}/${arch} to a temporary directory."
  download \
    "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${os}-${arch}" \
    "${KIND_BIN}"
  chmod +x "${KIND_BIN}"
}

cluster_exists() {
  "${KIND_BIN}" get clusters 2>/dev/null | grep -Fxq "${CLUSTER_NAME}"
}

create_cluster() {
  local kind_config="${WORK_DIR}/kind-config.yaml"

  if cluster_exists; then
    note "KinD cluster '${CLUSTER_NAME}' already exists; reusing it."
    "${KIND_BIN}" export kubeconfig --name "${CLUSTER_NAME}"
    return
  fi

  # A Linux host can expose /dev/kvm to the node container. Docker Desktop on
  # macOS cannot, so KubeVirt will use QEMU software emulation there.
  if [[ -c /dev/kvm ]]; then
    cat >"${kind_config}" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /dev/kvm
        containerPath: /dev/kvm
EOF
    note "Found /dev/kvm; exposing hardware virtualization to KinD."
  else
    cat >"${kind_config}" <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF
    note "/dev/kvm is unavailable; KubeVirt will use software emulation."
  fi

  if [[ "${HOST_PLATFORM}" == "darwin/arm64" ]]; then
    # A previous manual pull may have assigned this tag to another platform.
    docker pull --platform=linux/arm64 "${KIND_NODE_IMAGE}"
  fi

  "${KIND_BIN}" create cluster \
    --name "${CLUSTER_NAME}" \
    --image "${KIND_NODE_IMAGE}" \
    --config "${kind_config}" \
    --wait 180s
}

configure_kindnet_mtu() {
  # Docker Desktop presents a 65535-byte node interface, and KinD copies that
  # value into its default CNI config. KubeVirt tap devices use a conventional
  # Ethernet MTU, so normalize new pod interfaces before deploying the VM.
  docker exec "${NODE_NAME}" sed -i.bak -E \
    's/"mtu":[[:space:]]*[0-9]+/"mtu": 1500/' \
    /etc/cni/net.d/10-kindnet.conflist
  docker exec "${NODE_NAME}" grep -Eq \
    '"mtu":[[:space:]]*1500' /etc/cni/net.d/10-kindnet.conflist
  note "Kindnet pod MTU is fixed at 1500 for KubeVirt tap compatibility."
}

apply_arm_tcg_workaround() {
  local webhook_config
  webhook_config="$(kubectl get validatingwebhookconfigurations -o json |
    jq -r '.items[] | select(any(.webhooks[]?; .name == "virtualmachineinstances-create-validator.kubevirt.io")) | .metadata.name' |
    head -n 1)"
  if [[ -n "${webhook_config}" ]]; then
    kubectl get validatingwebhookconfiguration "${webhook_config}" -o json |
      jq 'del(.metadata.managedFields,
              .metadata.resourceVersion,
              .metadata.uid,
              .metadata.creationTimestamp,
              (.webhooks[] |
               select(.name == "virtualmachineinstances-create-validator.kubevirt.io")))' |
      kubectl replace -f -
  fi
  kubectl label node "${NODE_NAME}" \
    "cpu-model.node.kubevirt.io/${ARM_TCG_CPU_MODEL}=true" --overwrite
  note "Applied the local Arm/TCG CPU-validation workaround."
}

install_kubevirt() {
  local release_base
  release_base="https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}"

  kubectl apply -f "${release_base}/kubevirt-operator.yaml"
  wait_for_crd "kubevirts.kubevirt.io"
  kubectl apply -f "${release_base}/kubevirt-cr.yaml"

  if ! docker exec "${NODE_NAME}" test -c /dev/kvm; then
    USE_EMULATION="true"
    note "Enabling KubeVirt emulation for this environment."
    kubectl -n kubevirt patch kubevirt kubevirt --type=merge \
      --patch \
      '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
  else
    note "KubeVirt can access /dev/kvm; hardware virtualization remains enabled."
  fi

  kubectl -n kubevirt wait kubevirt kubevirt \
    --for=condition=Available --timeout=600s
  kubectl -n kubevirt wait kubevirt kubevirt \
    --for=condition=Degraded=false --timeout=300s

  if [[ "${HOST_PLATFORM}" == "darwin/arm64" ]]; then
    # Upstream KubeVirt currently validates only host-passthrough on Arm64,
    # while libvirt cannot use that model with TCG. For this hardware-free lab
    # only, remove the single VMI-create validator that blocks the TCG model.
    # The VM, network, and all remaining KubeVirt admission checks stay active.
    apply_arm_tcg_workaround
  fi
}

install_ovs_on_node() {
  if ! docker exec "${NODE_NAME}" sh -c \
    'command -v ovs-vsctl >/dev/null &&
     python3 -c "import netaddr,pyparsing" >/dev/null 2>&1' >/dev/null 2>&1; then
    note "Installing Open vSwitch inside the Linux KinD node."
    docker exec "${NODE_NAME}" bash -ceu \
      'apt-get update -qq
       DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
         openvswitch-switch python3-openvswitch python3-netaddr python3-pyparsing'
  else
    note "Open vSwitch is already installed inside the KinD node."
  fi

  # Debian's service wrapper handles OVSDB initialization. The ovs-ctl fallback
  # also works when the node image is not running a conventional init system.
  docker exec "${NODE_NAME}" bash -ceu \
    'if ! ovs-vsctl --timeout=5 show >/dev/null 2>&1; then
       service openvswitch-switch start ||
         /usr/share/openvswitch/scripts/ovs-ctl --system-id=random start
     fi'

  # Preserve a working bridge on repeat runs. Otherwise, first try the normal
  # kernel datapath. Docker Desktop kernels often need the netdev fallback.
  local existing_type
  existing_type="$(docker exec "${NODE_NAME}" ovs-vsctl \
    --if-exists get bridge "${OVS_BRIDGE}" datapath_type | tr -d '"')"
  if [[ "${existing_type}" == "netdev" ]]; then
    DATAPATH_TYPE="netdev"
    note "Reusing ${OVS_BRIDGE} with its userspace netdev datapath."
  elif docker exec "${NODE_NAME}" bash -ceu \
    "ovs-vsctl --may-exist add-br '${OVS_BRIDGE}'
     sleep 1
     ovs-appctl dpif/show | grep -Fq '${OVS_BRIDGE}'"; then
    DATAPATH_TYPE="system"
    note "OVS bridge ${OVS_BRIDGE} is using the kernel datapath."
  else
    note "Kernel OVS datapath is unavailable; falling back to userspace netdev."
    docker exec "${NODE_NAME}" bash -ceu \
      "ovs-vsctl --if-exists del-br '${OVS_BRIDGE}'
       ovs-vsctl add-br '${OVS_BRIDGE}' -- \
         set Bridge '${OVS_BRIDGE}' datapath_type=netdev
       sleep 1
       ovs-appctl dpif/show | grep -Fq '${OVS_BRIDGE}'"
    DATAPATH_TYPE="netdev"
  fi

  docker exec "${NODE_NAME}" \
    ovs-vsctl set bridge "${OVS_BRIDGE}" protocols=OpenFlow13
  # The netdev internal port otherwise reports MTU 65535 on Docker Desktop.
  # KubeVirt propagates that value to its tap, which Linux correctly rejects.
  docker exec "${NODE_NAME}" \
    ovs-vsctl set interface "${OVS_BRIDGE}" mtu_request=1500
  docker exec "${NODE_NAME}" \
    ip link set dev "${OVS_BRIDGE}" mtu 1500 up
}

install_network_addons() {
  local release_base
  release_base="https://github.com/kubevirt/cluster-network-addons-operator/releases/download/${CNAO_VERSION}"

  kubectl apply -f "${release_base}/namespace.yaml"
  kubectl apply -f "${release_base}/network-addons-config.crd.yaml"
  wait_for_crd "networkaddonsconfigs.networkaddonsoperator.network.kubevirt.io"
  kubectl apply -f "${release_base}/operator.yaml"
  wait_for_deployment "cluster-network-addons" "cluster-network-addons-operator"

  # The first phase contains the namespace and the NetworkAddonsConfig. CNAO
  # then installs Multus, the NAD CRD, and the OVS CNI binary on the node.
  apply_manifest_phase "addons"
  kubectl wait networkaddonsconfig cluster \
    --for=condition=Available --timeout=600s
  wait_for_crd "network-attachment-definitions.k8s.cni.cncf.io"
}

deploy_workloads() {
  apply_manifest_phase "workload"

  kubectl -n "${LAB_NAMESPACE}" wait pod ovs-peer \
    --for=condition=Ready --timeout=300s

  if [[ "${USE_EMULATION}" == "true" ]]; then
    # TCG on ARM cannot provide host-passthrough. Render the submitted VM
    # through kubectl and add a conservative QEMU ARM CPU model.
    if [[ "${HOST_PLATFORM}" == "darwin/arm64" ]]; then
      # The operator may have reconciled its webhook since installation.
      apply_arm_tcg_workaround
    fi
    render_manifest_phase "vm" |
      kubectl create --dry-run=client -f - -o json |
      jq --arg model "${ARM_TCG_CPU_MODEL}" \
        '.spec.template.spec.domain.cpu = ((.spec.template.spec.domain.cpu // {}) + {"model":$model})' |
      kubectl apply -f -
  else
    apply_manifest_phase "vm"
  fi

  # If this is a recovery run, replace only a VMI created with the wrong CPU
  # model. A correctly running VMI remains untouched.
  if [[ "${USE_EMULATION}" == "true" ]] &&
    kubectl -n "${LAB_NAMESPACE}" get vmi ovs-vm >/dev/null 2>&1 &&
    [[ "$(kubectl -n "${LAB_NAMESPACE}" get vmi ovs-vm \
      -o jsonpath='{.spec.domain.cpu.model}')" != "${ARM_TCG_CPU_MODEL}" ]]; then
    note "Replacing the earlier VMI with the emulation-safe CPU model."
    kubectl -n "${LAB_NAMESPACE}" delete vmi ovs-vm --wait=true
  fi

  # KubeVirt does not live-update disks or NIC definitions. Restart only when
  # the submitted VM template generation is newer than the running VMI.
  if kubectl -n "${LAB_NAMESPACE}" get vmi ovs-vm >/dev/null 2>&1; then
    local vm_generation vmi_generation
    vm_generation="$(kubectl -n "${LAB_NAMESPACE}" get vm ovs-vm \
      -o jsonpath='{.metadata.generation}')"
    vmi_generation="$(kubectl -n "${LAB_NAMESPACE}" get vmi ovs-vm \
      -o jsonpath='{.metadata.annotations.kubevirt\.io/vm-generation}')"
    if [[ "${vm_generation}" != "${vmi_generation}" ]]; then
      note "Restarting the VMI to apply the updated VM template."
      kubectl -n "${LAB_NAMESPACE}" patch vm ovs-vm --type=merge \
        --patch '{"spec":{"runStrategy":"Halted"}}'
      kubectl -n "${LAB_NAMESPACE}" wait vmi ovs-vm \
        --for=delete --timeout=120s 2>/dev/null || true
      if [[ "${HOST_PLATFORM}" == "darwin/arm64" ]]; then
        apply_arm_tcg_workaround
      fi
      kubectl -n "${LAB_NAMESPACE}" patch vm ovs-vm --type=merge \
        --patch '{"spec":{"runStrategy":"Always"}}'
    fi
  fi

  # A rerun should also recover from a previous, already diagnosed launch
  # failure. Cycling only CrashLoopBackOff VMs clears KubeVirt's retry delay;
  # a healthy VM is never restarted by this script.
  local vm_printable_status
  vm_printable_status="$(kubectl -n "${LAB_NAMESPACE}" get vm ovs-vm \
    -o jsonpath='{.status.printableStatus}' 2>/dev/null)"
  if [[ "${vm_printable_status}" == "CrashLoopBackOff" ||
    "${vm_printable_status}" == "Stopped" ]]; then
    note "Clearing the VM's previous crash backoff before retrying."
    kubectl -n "${LAB_NAMESPACE}" patch vm ovs-vm --type=merge \
      --patch '{"spec":{"runStrategy":"Halted"}}'
    kubectl -n "${LAB_NAMESPACE}" wait vmi ovs-vm \
      --for=delete --timeout=120s 2>/dev/null || true
    if [[ "${HOST_PLATFORM}" == "darwin/arm64" ]]; then
      apply_arm_tcg_workaround
    fi
    kubectl -n "${LAB_NAMESPACE}" patch vm ovs-vm --type=merge \
      --patch '{"spec":{"runStrategy":"Always"}}'
  fi

  # runStrategy=Always creates the VMI automatically. This loop avoids racing
  # the VM controller before the VMI object exists.
  local attempt
  for attempt in {1..60}; do
    if kubectl -n "${LAB_NAMESPACE}" get vmi ovs-vm >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  kubectl -n "${LAB_NAMESPACE}" get vmi ovs-vm >/dev/null
  kubectl -n "${LAB_NAMESPACE}" wait vmi ovs-vm \
    --for=condition=Ready --timeout=600s

  local port_count
  port_count="$(docker exec "${NODE_NAME}" \
    ovs-vsctl list-ports "${OVS_BRIDGE}" | sed '/^[[:space:]]*$/d' | wc -l |
    tr -d '[:space:]')"
  [[ "${port_count}" -ge 2 ]] ||
    die "Expected at least two ports on ${OVS_BRIDGE}; found ${port_count}."
  note "OVS bridge has ${port_count} workload ports."
}

install_observation_flows() {
  # NORMAL retains ordinary learning-switch behavior. The higher-priority ICMP
  # rules exist only to give the mentor unambiguous per-direction counters.
  # The distinctive cookie lets reruns replace only these observation rules
  # without disturbing OVS's default forwarding behavior.
  docker exec "${NODE_NAME}" ovs-ofctl -O OpenFlow13 \
    del-flows "${OVS_BRIDGE}" "cookie=${FLOW_COOKIE}/-1"
  docker exec "${NODE_NAME}" ovs-ofctl -O OpenFlow13 \
    add-flow "${OVS_BRIDGE}" \
    "cookie=${FLOW_COOKIE},priority=200,icmp,nw_src=${PEER_IP},nw_dst=${VM_IP},actions=NORMAL"
  docker exec "${NODE_NAME}" ovs-ofctl -O OpenFlow13 \
    add-flow "${OVS_BRIDGE}" \
    "cookie=${FLOW_COOKIE},priority=200,icmp,nw_src=${VM_IP},nw_dst=${PEER_IP},actions=NORMAL"
}

run_ping_test() {
  local attempt
  local guest_ready="false"
  note "Waiting for the guest OS to finish booting and configure its OVS NIC."
  for attempt in {1..60}; do
    if kubectl -n "${LAB_NAMESPACE}" exec ovs-peer -- \
      ping -c 1 -W 2 "${VM_IP}" >/dev/null 2>&1; then
      guest_ready="true"
      break
    fi
    if ((attempt % 10 == 0)); then
      note "Guest network is still booting (${attempt}/60 probes)."
    fi
    sleep 5
  done
  [[ "${guest_ready}" == "true" ]] ||
    die "The VM did not answer on ${VM_IP} within five minutes."

  # tee keeps the console useful for a person while preserving the exact ping
  # stdout required as the submission artifact.
  note "Pinging the VM's OVS-backed address ${VM_IP} from ${PEER_IP}."
  kubectl -n "${LAB_NAMESPACE}" exec ovs-peer -- \
    ping -c 4 -W 3 "${VM_IP}" | tee "${PING_OUTPUT}"

  grep -Eq '0% packet loss|0\.0% packet loss' "${PING_OUTPUT}" ||
    die "Ping completed without reporting zero packet loss."
}

capture_flows() {
  local text_dump="${WORK_DIR}/flows.txt"

  # Capture only after traffic has run; configured rules with zero counters
  # would show intent, but would not prove that a packet crossed the bridge.
  docker exec "${NODE_NAME}" ovs-ofctl -O OpenFlow13 \
    dump-flows "${OVS_BRIDGE}" >"${text_dump}"

  # Check the human-readable form because OVS JSON schemas vary slightly by
  # release. The submitted artifact remains the untouched JSON command output.
  [[ "$(grep -F "cookie=${FLOW_COOKIE}" "${text_dump}" |
    grep -Ec 'n_packets=[1-9][0-9]*')" -ge 2 ]] ||
    die "The forward and return ICMP rules do not both have packet counters."

  # ovs-ofctl's native dump is textual in OVS 3.1. Feed it through the official
  # packaged OFPFlow parser and FlowEncoder used by newer ovs-flowviz releases.
  docker exec "${NODE_NAME}" bash -o pipefail -ceu \
    "ovs-ofctl -O OpenFlow13 dump-flows '${OVS_BRIDGE}' |
       python3 -c 'import sys,json
from ovs.flow.ofp import OFPFlow
from ovs.flow.decoders import FlowEncoder
flows=[]
for line in sys.stdin:
    if \"actions=\" not in line:
        continue
    # Debian OVS 3.1 registers this field as n_packet even though ovs-ofctl
    # prints n_packets. Normalize it for parsing, then restore the real name.
    flow=OFPFlow(line.strip().replace(\"n_packets=\", \"n_packet=\")).dict()
    if \"n_packet\" in flow[\"info\"]:
        flow[\"info\"][\"n_packets\"]=flow[\"info\"].pop(\"n_packet\")
    flows.append(flow)
json.dump(flows,sys.stdout,cls=FlowEncoder)'" >"${FLOW_OUTPUT}"
  jq -e . "${FLOW_OUTPUT}" >/dev/null
  note "Captured valid raw OVS JSON with non-zero ICMP counters."
}

print_summary() {
  local vm_state ping_summary observed_flows
  vm_state="$(kubectl -n "${LAB_NAMESPACE}" \
    get vmi ovs-vm -o jsonpath='{.status.phase}')"
  ping_summary="$(tail -n 2 "${PING_OUTPUT}" | head -n 1)"
  observed_flows="$(docker exec "${NODE_NAME}" ovs-ofctl -O OpenFlow13 \
    dump-flows "${OVS_BRIDGE}" |
    grep -F "cookie=${FLOW_COOKIE}" |
    grep -Ec 'n_packets=[1-9][0-9]*')"

  printf '\n============================================================\n'
  printf 'Cloud-Native OVS datapath lab completed successfully\n'
  printf '============================================================\n'
  printf 'Cluster:          %s\n' "${CLUSTER_NAME}"
  printf 'VM state:         %s\n' "${vm_state}"
  printf 'OVS bridge:       %s (%s datapath)\n' "${OVS_BRIDGE}" "${DATAPATH_TYPE}"
  printf 'Observed flows:   %s ICMP directions\n' "${observed_flows}"
  printf 'Ping summary:     %s\n' "${ping_summary}"
  printf 'Ping evidence:    %s\n' "${PING_OUTPUT}"
  printf 'Flow evidence:    %s\n' "${FLOW_OUTPUT}"
  printf '\nThe cluster is still running for exploration.\n'
  printf 'Delete it later with: %s delete cluster --name %s\n' \
    "${KIND_BIN}" "${CLUSTER_NAME}"
}

main() {
  stage "1/7 - Checking prerequisites"
  for command in docker kubectl curl jq; do
    command -v "${command}" >/dev/null 2>&1 ||
      die "Required command '${command}' was not found."
  done
  docker info >/dev/null 2>&1 ||
    die "Docker is installed but its daemon is not reachable."
  [[ -r "${MANIFESTS_FILE}" ]] ||
    die "Cannot read ${MANIFESTS_FILE}."
  WORK_DIR="$(mktemp -d)"
  local platform
  platform="$(detect_platform)"
  HOST_PLATFORM="${platform}"
  note "Detected ${platform}."
  prepare_kind "${platform}"

  stage "2/7 - Creating or reusing the KinD cluster"
  create_cluster
  configure_kindnet_mtu

  stage "3/7 - Installing KubeVirt"
  install_kubevirt

  stage "4/7 - Preparing OVS, Multus, and OVS CNI"
  install_ovs_on_node
  install_network_addons

  stage "5/7 - Deploying the VM and OVS-connected peer"
  deploy_workloads

  stage "6/7 - Running the datapath ping test"
  install_observation_flows
  run_ping_test

  stage "7/7 - Capturing and validating OVS flows"
  capture_flows
  print_summary
}

main "$@"
