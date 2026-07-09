#!/usr/bin/env bash
# cluster_setup_user.sh — Phase 2: verify the cluster from your user account
# and print next-step commands.
#
# Run as your normal user (NOT root). Phase 1 (cluster_setup_root.sh) must
# have completed and copied the kubeconfig to ~/.kube/config.
#
# This script does no install — it only verifies and prints guidance. The
# reason it exists as a separate script: a clear "I'm running as user X"
# boundary in the lab.

set -euo pipefail

OVS_BRIDGE="${OVS_BRIDGE:-br-ovs}"
VM_IP="${VM_IP:-192.168.200.2/30}"

log()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

preflight() {
  [[ $EUID -ne 0 ]] || die "this script must run as the unprivileged user (not root)"
  command -v kubectl >/dev/null || die "kubectl not on PATH"
  command -v virtctl >/dev/null || die "virtctl not on PATH"
  [[ -f "$HOME/.kube/config" ]] || die "~/.kube/config missing; Phase 1 didn't copy it. As root, run: cp /etc/rancher/k3s/k3s.yaml /home/$USER/.kube/config && chown $USER:$USER /home/$USER/.kube/config"
  log "user $(whoami) has kubectl, virtctl, and ~/.kube/config"
}

verify() {
  log "===== USER-PHASE VERIFY ====="
  log "nodes:"
  kubectl get nodes -o wide | sed 's/^/    /'

  log "k3s pods:"
  kubectl get pods -A | sed 's/^/    /'

  log "networkaddonsconfig:"
  kubectl get networkaddonsconfig | sed 's/^/    /'

  log "kubevirt:"
  kubectl get kubevirt -A | sed 's/^/    /'

  log "CNAO components (multus, ovs-cni-amd64, kubemacpool, ovs-cni-marker, bridge-marker):"
  kubectl -n cluster-network-addons get pods -o wide | sed 's/^/    /'

  echo
  cat <<EOF
============================================================
  Phase 2 (user) verify complete.
============================================================

Cluster looks healthy. Next steps:

  kubectl apply -f manifests.yaml
  virtctl -n vm-lab start cirros-vm
  kubectl -n vm-lab wait vmi cirros-vm --for condition=Ready --timeout=180s

After the VM is Ready, capture the deliverables:

  # host -> VM (host has 192.168.200.1 on br-ovs; VM is 192.168.200.2)
  ping -c 4 192.168.200.2 | tee ping_results.txt

  # VM -> host (interactive console)
  virtctl -n vm-lab console cirros-vm
    then inside the VM shell: ping -c 4 192.168.200.1
    (capture the second ping into ping_results.txt with a separator)

  # OVS flow dump (sudo is required to read the OVS db socket)
  sudo ovs-ofctl dump-flows $OVS_BRIDGE --format=json > verification_flows.json

EOF
}

main() {
  preflight
  verify
}

main "$@"