#!/usr/bin/env python3
"""flows_to_json.py — parse `ovs-ofctl dump-flows` text into structured JSON.

Rationale: no released Open vSwitch implements `ovs-ofctl dump-flows --format=json`
(JSON output was added to `ovs-appctl` in OVS 3.4 and to the `ovs-flowviz` tool;
`ovs-ofctl` still prints plain text). This script performs the equivalent
transformation, producing the JSON schema documented in README.md, so that the
`verification_flows.json` deliverable is deterministically reproducible from the raw
`ovs-ofctl` text captured in `evidence/flows_raw.txt`.

Usage:
    ovs-ofctl dump-flows br1 | ./flows_to_json.py > verification_flows.flows.json
    ./flows_to_json.py < evidence/flows_raw.txt

Or (full evidence bundle, including datapath flows, FDB, ports and metadata):
    ./flows_to_json.py --bundle evidence/ --bridge br1 > verification_flows.json
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import re
import sys
from pathlib import Path
from typing import Any


NUMERIC_FIELDS = {
    "cookie", "duration", "n_packets", "n_bytes",
    "priority", "table", "idle_age", "hard_age",
}


def _coerce_number(key: str, value: str) -> Any:
    """Turn stringly-typed OVS fields into ints/floats where meaningful."""
    v = value.strip().rstrip("s")
    if key not in NUMERIC_FIELDS:
        return v
    try:
        if "." in v:
            return float(v)
        return int(v, 0)
    except ValueError:
        return v


def parse_openflow_line(line: str) -> dict[str, Any] | None:
    """Parse a single `ovs-ofctl dump-flows` line into a structured record.

    Returns None for non-flow lines (headers, blanks) so callers can filter.
    """
    line = line.strip()
    if not line or "actions=" not in line:
        return None

    head, _, actions = line.partition(" actions=")
    if not actions:
        # Some builds print `actions=…` without the leading space.
        head, _, actions = line.partition("actions=")

    fields: dict[str, Any] = {"orig": line}
    match_tokens: list[str] = []

    for tok in (t.strip() for t in head.split(",") if t.strip()):
        if "=" in tok:
            k, v = tok.split("=", 1)
            k = k.strip()
            if k in NUMERIC_FIELDS or k in ("cookie", "table"):
                fields[k] = _coerce_number(k, v)
            else:
                match_tokens.append(f"{k}={v.strip()}")
        else:
            match_tokens.append(tok)

    fields["duration_s"] = fields.pop("duration", 0.0)
    fields["match"] = ",".join(match_tokens) if match_tokens else "*"
    fields["actions"] = actions.strip()
    return fields


def parse_datapath_line(line: str) -> dict[str, Any] | None:
    line = line.strip()
    if not line or "actions:" not in line:
        return None
    pkts = re.search(r"packets:(\d+)", line)
    byts = re.search(r"bytes:(\d+)", line)
    used = re.search(r"used:([\d.]+)s", line)
    return {
        "orig": line,
        "packets": int(pkts.group(1)) if pkts else 0,
        "bytes": int(byts.group(1)) if byts else 0,
        "used_s": float(used.group(1)) if used else None,
        "actions": line.split("actions:")[1].strip(),
    }


def parse_fdb(text: str) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    for line in text.splitlines():
        m = re.match(r"\s*(\d+)\s+(\d+)\s+([0-9a-f:]{17})\s+([\d.]+|LOCAL)", line)
        if m:
            entries.append({
                "port": int(m.group(1)),
                "vlan": int(m.group(2)),
                "mac": m.group(3),
                "age_s": m.group(4),
            })
    return entries


def parse_ports(text: str) -> list[dict[str, Any]]:
    ports: list[dict[str, Any]] = []
    for line in text.splitlines():
        m = re.match(r"\s*(\d+|LOCAL)\((\S+)\): addr:([0-9a-f:]{17})", line)
        if m:
            ports.append({
                "ofport": m.group(1),
                "name": m.group(2),
                "mac": m.group(3),
            })
    return ports


def flows_from_stdin() -> list[dict[str, Any]]:
    flows = [parse_openflow_line(l) for l in sys.stdin.read().splitlines()]
    return [f for f in flows if f is not None]


def bundle(evidence_dir: Path, bridge: str, node: str | None,
           ovs_version: str | None) -> dict[str, Any]:
    def read(name: str) -> str:
        p = evidence_dir / name
        return p.read_text() if p.is_file() else ""

    flows_raw = read("flows_raw.txt")
    dp_raw = read("datapath_raw.txt")
    fdb_raw = read("fdb.txt")
    ports_raw = read("ports.txt")
    vsctl_raw = read("bridge_topology.txt")

    flows = [f for f in (parse_openflow_line(l) for l in flows_raw.splitlines()) if f]
    dp_flows = [d for d in (parse_datapath_line(l) for l in dp_raw.splitlines()) if d]

    access_vlans = sorted({int(t) for t in re.findall(r"tag:\s*(\d+)", vsctl_raw)})

    # Prefer the timestamp already recorded in execution_mode.txt so the bundle
    # timestamp stays stable across regenerations. Fall back to now() only when
    # that file is absent (e.g. first run before execution_mode.txt exists).
    em_raw = read("execution_mode.txt")
    m = re.search(r"timestamp_utc:\s+(\S+)", em_raw)
    now = m.group(1) if m else _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    doc: dict[str, Any] = {
        "_meta": {
            "generated_by": "flows_to_json.py --bundle",
            "timestamp_utc": now,
            "bridge": bridge,
            "node": node,
            "ovs_version": ovs_version,
            "flow_dump_method": "parsed-from-text",
            "access_vlans": access_vlans,
            "note": (
                "'ovs-ofctl dump-flows --format=json' is not implemented by released "
                "OVS; JSON was produced via the documented fallback and native output "
                "is embedded when the flag exists."
            ),
        },
        "bridge": bridge,
        "flows": flows,
        "datapath_flows": dp_flows,
        "fdb": parse_fdb(fdb_raw),
        "ports": parse_ports(ports_raw),
        "bridge_topology": vsctl_raw,
    }
    return doc


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--bundle", type=Path, metavar="DIR",
                    help="Assemble a full evidence bundle from an evidence/ directory.")
    ap.add_argument("--bridge", default="br1", help="Bridge name for --bundle mode.")
    ap.add_argument("--node", default=None,
                    help="Node name to record in --bundle mode metadata.")
    ap.add_argument("--ovs-version", default=None,
                    help="OVS version string to record in --bundle mode metadata.")
    args = ap.parse_args()

    if args.bundle is not None:
        doc = bundle(args.bundle, args.bridge, args.node, args.ovs_version)
        json.dump(doc, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return

    flows = flows_from_stdin()
    json.dump(flows, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
