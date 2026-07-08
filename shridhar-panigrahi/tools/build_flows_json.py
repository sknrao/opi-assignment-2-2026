#!/usr/bin/env python3
"""Assemble verification_flows.json from the live cluster.

ovs-ofctl in OVS 3.5.0 has no --format=json (the option exists only for
ovsdb-backed tools like ovs-vsctl), so the flow dump is parsed into JSON
field by field with each raw line preserved, and the native-JSON OVSDB
tables are included alongside.
"""
import json
import re
import subprocess
import datetime

NODE = "opi-ovs-control-plane"


def node_exec(cmd):
    return subprocess.run(["docker", "exec", NODE] + cmd,
                          capture_output=True, text=True, check=True).stdout


def parse_ofctl_flow(line):
    entry = {"raw": line.strip()}
    for key, pattern, cast in [
        ("cookie", r"cookie=(0x[0-9a-f]+)", str),
        ("duration_s", r"duration=([\d.]+)s", float),
        ("table", r"table=(\d+)", int),
        ("n_packets", r"n_packets=(\d+)", int),
        ("n_bytes", r"n_bytes=(\d+)", int),
        ("idle_age_s", r"idle_age=(\d+)", int),
        ("priority", r"priority=(\d+)", int),
        ("actions", r"actions=(\S+)", str),
    ]:
        m = re.search(pattern, line)
        if m:
            entry[key] = cast(m.group(1))
    return entry


ofctl_out = node_exec(["ovs-ofctl", "dump-flows", "br1"])
flow_lines = [l for l in ofctl_out.splitlines() if "cookie=" in l]

megaflows = sorted(set(
    l.strip() for l in open("megaflows_raw.txt")
    if l.strip() and "eth_type" in l
))

ovsdb = {}
for table in ["bridge", "port", "interface"]:
    out = node_exec(["ovs-vsctl", "--format=json", "list", table])
    ovsdb[table] = json.loads(out)

doc = {
    "assumption_note": (
        "The assignment suggests 'ovs-ofctl dump-flows <bridge> --format=json', "
        "but ovs-ofctl in Open vSwitch 3.5.0 does not implement a --format "
        "option (verified on this node: \"unrecognized option '--format=json'\"). "
        "Native JSON output exists only for OVSDB tools such as ovs-vsctl. "
        "This file therefore contains: (1) the OpenFlow flow dump parsed into "
        "JSON with every raw line preserved, (2) datapath megaflow-cache "
        "samples taken while a ping was running between the two VMs, showing "
        "the VM MACs and IPv4 traffic being forwarded between the OVS ports, "
        "and (3) the native-JSON OVSDB views of the bridge, ports and "
        "interfaces."
    ),
    "environment": {
        "node": NODE,
        "bridge": "br1",
        "ovs_version": node_exec(["ovs-vsctl", "--version"]).splitlines()[0],
        "captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    },
    "openflow_flow_dump": {
        "command": "ovs-ofctl dump-flows br1",
        "entries": [parse_ofctl_flow(l) for l in flow_lines],
    },
    "datapath_megaflows_sampled_during_ping": {
        "command": "ovs-appctl dpctl/dump-flows (sampled every 3s during a 30-packet ping vm-a -> vm-b)",
        "entries": megaflows,
    },
    "ovsdb_native_json": {
        "command": "ovs-vsctl --format=json list <bridge|port|interface>",
        "tables": ovsdb,
    },
}

with open("verification_flows.json", "w") as fh:
    json.dump(doc, fh, indent=2)

json.load(open("verification_flows.json"))
print("verification_flows.json written and re-parsed OK:",
      len(doc["openflow_flow_dump"]["entries"]), "openflow entries,",
      len(megaflows), "unique megaflows")
