# Evidence Reproduction Record

`ping_results.txt`, `verification_flows.json`, and the `evidence/` bundle are generated
by a successful `cluster_setup.sh` run. The paths below document equivalent reproduction routes used for review.

## Path 1 — GitHub Actions (primary review path)

The repo ships a workflow that runs the whole stack on a GHA `ubuntu-latest` runner with
**real nested KVM** (`-accel kvm` — see `evidence/kvm_proof.txt`) and uploads the full
evidence bundle as an artifact. This is how the committed evidence was produced.

```bash
# from the repo, with the GitHub CLI authenticated
gh workflow run "Capture OVS Evidence"
gh run watch
gh run download --name ovs-evidence -D artifacts
cp artifacts/ping_results.txt artifacts/verification_flows.json .
cp -r artifacts/evidence .
```

The `Verify artifacts` step gates the build on ≥4 `0% packet loss` blocks (2 pod↔VM
+ 2 VM↔VM via `virtctl console`), a populated `verification_flows.json`, an
`evidence/` bundle, and a parser round-trip check — a green run guarantees genuine
evidence.

## Path 2 — Linux host with Docker + `/dev/kvm`

```bash
docker info                       # daemon must be running
ls -la /dev/kvm                   # present => guests boot in minutes under KVM
chmod +x cluster_setup.sh verify_datapath.sh flows_to_json.py
./cluster_setup.sh                # bootstrap + verify + capture
```

Artifacts land next to the script. Tear down with `CLEANUP=1 ./cluster_setup.sh`.

Re-run verification only (without rebuilding the cluster):

```bash
./verify_datapath.sh
```

## Path 3 — Apple Silicon / no KVM (slow, best-effort)

`cluster_setup.sh` auto-detects the missing `/dev/kvm`, installs KubeVirt v1.9 with
the `CrossArchitectureVirtualization` gate, and runs the guests as amd64 under QEMU
TCG. Boot can take tens of minutes; Paths 1–2 provide faster and more reliable captures.

## Local artifact validation

```bash
# 4 zero-loss blocks: pod→vm-a, pod→vm-b, vm-a→vm-b (console), vm-b→vm-a (console)
grep -c "0% packet loss" ping_results.txt        # expect 4

cmp -s evidence/flows_raw.txt evidence/flows_after.txt && echo "flows alias OK"

# JSON has 5 classifier flows, 7 datapath megaflows, 6 FDB entries
python3 -c "import json; d=json.load(open('verification_flows.json')); \
  print('flows:', len(d['flows']), 'datapath:', len(d['datapath_flows']), 'fdb:', len(d['fdb']))"

# Round-trip: raw text → parser → JSON must match committed JSON counts
python3 flows_to_json.py --bundle evidence --bridge br1 > /tmp/rt.json
python3 -c "import json; a=json.load(open('verification_flows.json')); \
  b=json.load(open('/tmp/rt.json')); \
  for k in ('flows','datapath_flows','fdb','ports'): \
    assert len(a[k])==len(b[k]), k; \
  print('round-trip OK')"

# Full reviewer walkthrough: see SUBMIT.md
```
