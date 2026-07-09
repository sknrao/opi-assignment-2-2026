#!/usr/bin/env bash
# cluster_setup.sh — top-level entry point. Dispatches to the right phase
# depending on whether we're running as root or as the unprivileged user.
#
#   sudo ./cluster_setup.sh        # Phase 1 (cluster bring-up, root)
#   ./cluster_setup.sh            # Phase 2 (post-install verify, user)
#
# The split exists because:
#   - k3s install + systemd unit + ovs-vsctl + ip addr all need root
#   - kubectl + virtctl are user-level, but they don't need a privileged user

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -eq 0 ]]; then
  exec bash "$SCRIPT_DIR/cluster_setup_root.sh" "$@"
else
  exec bash "$SCRIPT_DIR/cluster_setup_user.sh" "$@"
fi