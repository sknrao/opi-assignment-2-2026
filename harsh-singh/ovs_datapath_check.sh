#!/usr/bin/env bash
# Quick real OVS datapath check: install Open vSwitch if needed, create a bridge,
# attach two network namespaces (stand-ins for VM taps), ping across it, and dump
# the flows. No Kubernetes and no KVM required. Run as root on a Linux host, or in
# a privileged Linux container:
#   docker run --rm --privileged -v "$PWD/ovs_datapath_check.sh:/x.sh" ubuntu:22.04 bash /x.sh
set -e

if [[ "$(id -u)" != "0" ]]; then echo "run as root (sudo)"; exit 1; fi

# 1. install Open vSwitch + tooling if not present
if ! command -v ovs-vsctl >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq openvswitch-switch iproute2 iputils-ping
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y openvswitch iproute iputils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y openvswitch iproute iputils
  else
    echo "no supported package manager; install openvswitch, iproute2, iputils-ping manually"; exit 1
  fi
fi

# 2. make sure the OVS daemons are running
(systemctl start openvswitch-switch 2>/dev/null) || \
  /usr/share/openvswitch/scripts/ovs-ctl start --system-id=random >/dev/null 2>&1 || true

echo "Open vSwitch: $(ovs-vsctl --version | head -1)"
echo "host: $(uname -srm)"

BR=br1
ovs-vsctl --if-exists del-br "$BR"
for n in 1 2; do ip netns del "vm$n" 2>/dev/null || true; done

# 3. bridge + two netns endpoints (like two VM taps on the bridge)
ovs-vsctl add-br "$BR"
ovs-vsctl set bridge "$BR" fail-mode=standalone
for n in 1 2; do
  ip netns add "vm$n"
  ip link add "veth$n" type veth peer name "ovs-vm$n"
  ip link set "veth$n" netns "vm$n"
  ovs-vsctl add-port "$BR" "ovs-vm$n"
  ip link set "ovs-vm$n" up
done
ip netns exec vm1 ip link set veth1 address 02:00:00:00:00:01
ip netns exec vm1 ip addr add 10.10.0.1/24 dev veth1
ip netns exec vm1 ip link set veth1 up
ip netns exec vm2 ip link set veth2 address 02:00:00:00:00:02
ip netns exec vm2 ip addr add 10.10.0.2/24 dev veth2
ip netns exec vm2 ip link set veth2 up

# 4. ping across the OVS datapath, capture
echo
echo "===== ping_results.txt ====="
{
  echo "# ip netns exec vm1 ping -c 4 10.10.0.2 (over OVS bridge $BR)"
  echo "# host $(uname -srm) ; $(ovs-vsctl --version | head -1) ; $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ip netns exec vm1 ping -c 4 10.10.0.2
} | tee ping_results.txt

# 5. dump flows + FDB as JSON
echo
echo "===== verification_flows.json ====="
FLOWS=$(ovs-ofctl dump-flows "$BR" | grep cookie= | sed 's/^[ \t]*//')
FDB=$(ovs-appctl fdb/show "$BR" | tail -n +2)
{
  printf '{\n  "bridge": "%s",\n  "flows": [\n' "$BR"
  first=1
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [ $first -eq 0 ] && printf ',\n'
    printf '    {"raw": "%s"}' "$line"
    first=0
  done <<< "$FLOWS"
  printf '\n  ],\n  "fdb_raw": [\n'
  first=1
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [ $first -eq 0 ] && printf ',\n'
    printf '    "%s"' "$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]\+/ /g')"
    first=0
  done <<< "$FDB"
  printf '\n  ]\n}\n'
} | tee verification_flows.json

echo
echo "Done. Send back ping_results.txt and verification_flows.json."
