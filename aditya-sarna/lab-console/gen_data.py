#!/usr/bin/env python3
"""Generate docs/data.js from repo evidence files."""
import json
import re
import sys
from pathlib import Path


def parse_ping_directions(ping):
    directions = []
    specs = [
        {
            "label": "pod → vm-a",
            "source": "ovs-ping-pod",
            "target": "vm-a",
            "targetIp": "10.10.0.10",
            "method": "kubectl",
            "starts": [r"\$ kubectl exec ovs-ping-pod -- ping -c \d+ 10\.10\.0\.10"],
        },
        {
            "label": "pod → vm-b",
            "source": "ovs-ping-pod",
            "target": "vm-b",
            "targetIp": "10.10.0.11",
            "method": "kubectl",
            "starts": [r"\$ kubectl exec ovs-ping-pod -- ping -c \d+ 10\.10\.0\.11"],
        },
        {
            "label": "vm-a → vm-b",
            "source": "vm-a",
            "target": "vm-b",
            "targetIp": "10.10.0.11",
            "method": "virtctl",
            "starts": [r"DIRECTION 3:.*", r"\$ virtctl console vm-a[^\n]*", r"----- DIRECTION: vm-a[^\n]*"],
        },
        {
            "label": "vm-b → vm-a",
            "source": "vm-b",
            "target": "vm-a",
            "targetIp": "10.10.0.10",
            "method": "virtctl",
            "starts": [r"DIRECTION 4:.*", r"\$ virtctl console vm-b[^\n]*", r"----- DIRECTION: vm-b[^\n]*"],
        },
    ]

    # Find the first matching marker for each logical direction.
    found = []
    for spec in specs:
        match = None
        for pat in spec["starts"]:
            m = re.search(pat, ping)
            if m and (match is None or m.start() < match.start()):
                match = m
        if match:
            found.append((match.start(), match.end(), spec))

    found.sort(key=lambda x: x[0])
    for idx, (start, _end, spec) in enumerate(found):
        nxt = found[idx + 1][0] if idx + 1 < len(found) else len(ping)
        block = ping[start:nxt].strip()
        directions.append(
            {
                "id": spec["label"].replace(" ", "-").replace("→", "to"),
                "label": spec["label"],
                "source": spec["source"],
                "target": spec["target"],
                "targetIp": spec["targetIp"],
                "method": spec["method"],
                "pass": "0% packet loss" in block,
                "ttl64": "ttl=64" in block,
                "text": block,
            }
        )
    return directions


REPO_URL = "https://github.com/Aditya-Sarna/opi-assignment-2-ovs"
CI_RUN_URL = "https://github.com/Aditya-Sarna/opi-assignment-2-ovs/actions/runs/28830867232"
ASSIGNMENT_REPO_URL = "https://github.com/sknrao/opi-assignment-2-2026"


def parse_execution_mode(path):
    if not path or not path.exists():
        return {}
    text = path.read_text()
    use_emulation = ""
    for header in (
        "=== KubeVirt useEmulation ===",
        "=== KubeVirt developerConfiguration.useEmulation ===",
    ):
        if header not in text:
            continue
        block = text.split(header, 1)[1]
        for line in block.splitlines():
            stripped = line.strip()
            if stripped.startswith("==="):
                break
            if stripped and not stripped.startswith("#"):
                use_emulation = stripped
                break
        break
    if not use_emulation and re.search(r"useEmulation=true", text):
        use_emulation = "true"
    accel = "-accel kvm" if "-accel kvm" in text else ("-accel tcg" if "-accel tcg" in text else "")
    kvm_present = "/dev/kvm" in text and "(no /dev/kvm)" not in text
    vmx_m = re.search(r"=== vmx/svm CPU flags \(count\) ===\s*\n(\d+)", text)
    return {
        "useEmulation": use_emulation,
        "accel": accel,
        "kvmPresent": kvm_present,
        "vmxCount": int(vmx_m.group(1)) if vmx_m else None,
        "raw": text.strip(),
    }


def main():
    vflows_path = Path(sys.argv[1])
    ping_path = Path(sys.argv[2])
    before_path = Path(sys.argv[3]) if len(sys.argv) > 3 else None
    after_path = Path(sys.argv[4]) if len(sys.argv) > 4 else None
    exec_path = Path(sys.argv[5]) if len(sys.argv) > 5 else vflows_path.parent / "evidence" / "execution_mode.txt"
    kvm_path = vflows_path.parent / "evidence" / "kvm_proof.txt"

    evidence = json.loads(vflows_path.read_text())
    ping = ping_path.read_text()
    before = before_path.read_text() if before_path and before_path.exists() else ""
    after = after_path.read_text() if after_path and after_path.exists() else ""
    kvm_proof = kvm_path.read_text().strip() if kvm_path.exists() else ""

    execution_mode = parse_execution_mode(exec_path if exec_path.exists() else None)
    if kvm_proof:
        vmx_m = re.search(r"=== vmx/svm CPU flags \(count\) ===\s*\n(\d+)", kvm_proof)
        if vmx_m:
            execution_mode["vmxCount"] = int(vmx_m.group(1))
        if not execution_mode.get("accel") and "-accel kvm" in kvm_proof:
            execution_mode["accel"] = "-accel kvm"
        if "/dev/kvm" in kvm_proof:
            execution_mode["kvmPresent"] = True

    cf = [f for f in evidence.get("flows", []) if "nw_src" in (f.get("match") or "")]
    active_mf = [f for f in evidence.get("datapath_flows", []) if (f.get("packets") or 0) > 0]

    data = {
        "meta": evidence.get("_meta", {}),
        "bridge": evidence.get("bridge", "br1"),
        "flows": evidence.get("flows", []),
        "datapathFlows": evidence.get("datapath_flows", []),
        "fdb": evidence.get("fdb", []),
        "ports": evidence.get("ports", []),
        "bridgeTopology": evidence.get("bridge_topology", ""),
        "pingBlocks": ping.count("0% packet loss"),
        "pingText": ping,
        "pingDirections": parse_ping_directions(ping),
        "flowsBefore": before,
        "flowsAfter": after,
        "executionMode": execution_mode,
        "kvmProof": kvm_proof,
        "stats": {
            "classifierRules": len(cf),
            "classifierMinPackets": min((f.get("n_packets") or 0) for f in cf) if cf else 0,
            "megaflowTotal": len(evidence.get("datapath_flows", [])),
            "megaflowActive": len(active_mf),
            "megaflowMaxPackets": max((f.get("packets") or 0) for f in evidence.get("datapath_flows", [])) or 0,
            "fdbVlan100": len([e for e in evidence.get("fdb", []) if e.get("vlan") == 100]),
            "hasPushVlan": any("push_vlan" in (f.get("actions") or "") for f in evidence.get("datapath_flows", [])),
        },
        "links": {
            "repo": REPO_URL,
            "ci": CI_RUN_URL,
            "diagram": "https://raw.githubusercontent.com/Aditya-Sarna/opi-assignment-2-ovs/main/diagrams/implemented_software_datapath_topology.png",
            "submit": f"{REPO_URL}/blob/main/SUBMIT.md",
            "assignment": ASSIGNMENT_REPO_URL,
        },
        "topology": {
            "bridge": {"id": "br1", "label": "br1", "vlan": 100},
            "nodes": [
                {"id": "vm-a", "type": "vm", "ip": "10.10.0.10", "mac": "02:a0:00:00:00:0a"},
                {"id": "vm-b", "type": "vm", "ip": "10.10.0.11", "mac": "02:a0:00:00:00:0b"},
                {"id": "ovs-ping-pod", "type": "pod", "ip": "10.10.0.20", "mac": "02:a0:00:00:00:14"},
            ],
            "edges": [
                {"from": "vm-a", "to": "br1"},
                {"from": "vm-b", "to": "br1"},
                {"from": "ovs-ping-pod", "to": "br1"},
            ],
        },
        "journey": [
            {"id": "bootstrap", "title": "Full stack bootstrap", "detail": "Single script provisions KinD, Open vSwitch, Multus, OVS-CNI, and KubeVirt end to end.", "proof": "cluster_setup.sh"},
            {"id": "kindnet", "title": "Flannel → kindnet", "problem": "Flannel crashed on recent kernels; every pod sandbox failed.", "fix": "KinD built-in kindnet as default CNI. OVS bridge layered via Multus.", "proof": "cluster_setup.sh (create_cluster)"},
            {"id": "vlan100", "title": "VLAN 100 access ports", "detail": "NAD declares vlan: 100. push_vlan(vid=100) appears in kernel megaflow actions.", "proof": "manifests.yaml · verification_flows.json"},
            {"id": "classifiers", "title": "Per-source classifier rules", "detail": "install_classifier_flows() adds nw_src= rules. flows_before = 1 NORMAL rule; flows_after = 5 rules with hits.", "proof": "evidence/flows_before.txt vs flows_after.txt"},
            {"id": "vmvm", "title": "VM-to-VM console pings", "detail": "virtctl console + expect drives bidirectional in-guest pings across br1.", "proof": "ping_results.txt · console_ping_*.txt"},
            {"id": "megaflows", "title": "Kernel megaflow cache", "detail": "dpctl/dump-flows captures per-MAC-pair entries — the objects offloaded to BlueField-3 eSwitch.", "proof": "verification_flows.json datapath_flows"},
            {"id": "ci", "title": "CI-gated reproducibility", "detail": "GitHub Actions fails unless ≥4 ping blocks, classifier hits, and parser round-trip pass.", "proof": ".github/workflows/capture.yml"},
        ],
    }

    print("/* AUTO-GENERATED by lab-console/gen_data.py — do not edit by hand */")
    print("window.APP_DATA = " + json.dumps(data, indent=2) + ";")


if __name__ == "__main__":
    main()
