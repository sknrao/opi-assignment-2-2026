# Mentor Review Checklist (5 minutes)

## Quick Links

- App (GitHub Pages): https://aditya-sarna.github.io/opi-assignment-2-ovs/
- Repository: https://github.com/Aditya-Sarna/opi-assignment-2-ovs
- Workflow runs (all): https://github.com/Aditya-Sarna/opi-assignment-2-ovs/actions/workflows/capture.yml
- Latest successful run: https://github.com/Aditya-Sarna/opi-assignment-2-ovs/actions/runs/28868065521

## Review prerequisites

```bash
git clone <assignment-fork> && cd <repo>/aditya-sarna
python3 --version   # any 3.8+
```

No cluster is required for this review flow. The checks below execute locally against committed files.

## Option B PR packaging (included)

This submission uses the top-level folder `aditya-sarna`, with required deliverables and supporting artifacts collocated for reviewer traceability.

## Step 1 — Topology scan (30 sec)

```
br1 (OVS, VLAN 100 access ports)
  ├── vm-a   CirrOS   eth1 = 10.10.0.10   MAC 02:a0:00:00:00:0a
  ├── vm-b   CirrOS   eth1 = 10.10.0.11   MAC 02:a0:00:00:00:0b
  └── pod    Alpine   net1 = 10.10.0.20   MAC 02:a0:00:00:00:14
```

Two VMs + one pod, all on the same OVS bridge. Per-source classifier rules installed
before the pings so the evidence proves classification, not just forwarding.

## Step 2 — Flow evidence checks (1 min)

```bash
# See classifier rules with non-zero hit counts
cat evidence/flows_before.txt   # single NORMAL rule before install_classifier_flows()
cat evidence/flows_after.txt    # 5 rules after; nw_src rules show n_packets=13/13/8

# flows_raw and flows_after must be identical (capture keeps them in sync)
cmp -s evidence/flows_raw.txt evidence/flows_after.txt && echo "flows_raw == flows_after OK"

# Verify the JSON is a clean parse of the raw text (no hand-authored fields)
python3 flows_to_json.py --bundle evidence --bridge br1 > /tmp/roundtrip.json
python3 -c "
import json
a = json.load(open('verification_flows.json'))
b = json.load(open('/tmp/roundtrip.json'))
assert len(a['flows']) == len(b['flows']), 'flows count mismatch'
assert len(a['datapath_flows']) == len(b['datapath_flows']), 'datapath mismatch'
assert len(a['fdb']) == len(b['fdb']), 'fdb mismatch'
print('PASS: JSON matches round-trip parse of raw text')
print(f'  flows={len(a[\"flows\"])} datapath={len(a[\"datapath_flows\"])} fdb={len(a[\"fdb\"])} access_vlans={a[\"_meta\"][\"access_vlans\"]}')
"
```

Expected output signature:
```
PASS: JSON matches round-trip parse of raw text
  flows=5 datapath=7 fdb=6 access_vlans=[100]
```

## Step 3 — Ping evidence checks (1 min)

```bash
# 4 zero-loss blocks: pod→vm-a, pod→vm-b, vm-a→vm-b, vm-b→vm-a
grep -c "0% packet loss" ping_results.txt   # → 4

# Every reply is ttl=64 (L2 hop, not routed)
grep "ttl=" ping_results.txt | sort -u

# VM↔VM console transcripts (virtctl console + expect)
cat evidence/console_ping_vm-a_to_vm-b.txt
cat evidence/console_ping_vm-b_to_vm-a.txt
```

## Step 4 — MAC trace: manifest → FDB → megaflow (1 min)

```bash
python3 -c "
import json
d = json.load(open('verification_flows.json'))

# vm-a's pinned MAC
mac = '02:a0:00:00:00:0a'
fdb_entry = next(e for e in d['fdb'] if e['mac'] == mac)
print(f'FDB: {mac} learned on port {fdb_entry[\"port\"]}, VLAN {fdb_entry[\"vlan\"]}')

# Find megaflows where vm-a is the source
vm_a_flows = [f for f in d['datapath_flows'] if mac in f['orig'] and 'src=' + mac in f['orig']]
for f in vm_a_flows:
    print(f'  megaflow: packets={f[\"packets\"]} bytes={f[\"bytes\"]} actions={f[\"actions\"]}')
"
```

Expected signal: `mac learned on port N, VLAN 100` and at least one active megaflow
with `packets=9` for vm-a→vm-b and vm-b→vm-a IPv4 (`actions=4` / `actions=3`).

## Step 5 — Execution mode disclosure (30 sec)

```bash
cat evidence/execution_mode.txt   # useEmulation disabled, -accel kvm
cat evidence/kvm_proof.txt        # /dev/kvm in KinD node, vmx flags, -accel kvm
```

## Step 6 — CI reproduction (optional, ~20 min)

```bash
# Fork the repo, then:
gh workflow run "Capture OVS Evidence"
gh run watch
gh run download --name ovs-evidence -D artifacts
diff artifacts/verification_flows.json verification_flows.json  # expected: schema-compatible output
```

The `Verify artifacts` CI step fails unless:
- `ping_results.txt` has ≥4 `0% packet loss` blocks (2 pod↔VM + 2 VM↔VM console)
- `evidence/flows_raw.txt` and `evidence/flows_after.txt` are identical
- `verification_flows.json` has non-empty `flows` and `fdb`
- `flows_to_json.py --bundle evidence` reproduces the same `flows`, `datapath_flows`, `fdb`, and `ports` counts as the committed JSON

A green run is an independent assertion that the evidence is genuine and reproducible.
