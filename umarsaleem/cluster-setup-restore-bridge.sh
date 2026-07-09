#!/usr/bin/env bash
# cluster-setup-restore-bridge.sh
#
# Re-apply the OVS bridge link state and IP address that are lost when
# the host reboots. Designed to be called from a systemd oneshot unit
# (cluster-setup-restore-bridge.service) so the recovery is automatic
# on every boot.
#
# Idempotent: every line tolerates a partial state.
#
# Why this exists:
#   cluster_setup_root.sh's `create_ovs_bridge` function correctly
#   brings up the bridge and assigns the IP, but only when the user
#   invokes the script manually. After a host reboot, br-ovs comes
#   back DOWN with no IP. This script ensures the lab is usable
#   immediately after boot, without a manual command.
#
# Invocation:
#   sudo /usr/local/bin/cluster-setup-restore-bridge.sh
#
# Exit codes:
#   0 on success (including no-op).
#   non-zero only on hard errors that would block the lab.

set -euo pipefail

OVS_BRIDGE="${OVS_BRIDGE:-br-ovs}"
OVS_BRIDGE_IP="${OVS_BRIDGE_IP:-192.168.200.1/30}"

log() { printf '[restore] %s\n' "$*" >&2; }

if ! ip link show "${OVS_BRIDGE}" >/dev/null 2>&1; then
  log "WARN: ${OVS_BRIDGE} interface does not exist yet. OVS may not have started, or br-ovs was deleted. The cluster_setup_root.sh script must be run manually to recreate it."
  exit 0
fi

log "setting ${OVS_BRIDGE} up"
ip link set "${OVS_BRIDGE}" up

# 'ip addr add' is idempotent: returns success if the address is already
# present, returns an error only if a *different* address is on the
# interface (which would indicate misconfiguration).
if ip addr show dev "${OVS_BRIDGE}" | grep -q "${OVS_BRIDGE_IP%/*}"; then
  log "${OVS_BRIDGE_IP} already on ${OVS_BRIDGE}"
else
  log "adding ${OVS_BRIDGE_IP} to ${OVS_BRIDGE}"
  ip addr add "${OVS_BRIDGE_IP}" dev "${OVS_BRIDGE}" || {
    log "WARN: failed to add ${OVS_BRIDGE_IP} to ${OVS_BRIDGE} (an address is already configured there)"
  }
fi

log "done"
