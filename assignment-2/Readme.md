# Assignment 2 — Cloud-Native OVS Datapath

Two CirrOS KubeVirt VMs on an Open vSwitch bridge, with verified east-west
connectivity and captured flow evidence. I built and tested this on **real KVM**
(hardware virtualization), and added an emulation fallback so it also runs on
machines without it.

### Quick start

From WSL2 Ubuntu (Docker installed), in this directory:

```bash
./cluster_setup.sh
```
Note if KVM enabled(Hardware Virtualisation) is not enabled run:
```bash
ALLOW_EMULATION=1 ./cluster_setup.sh
```

One command, end to end: minikube → OVS, Multus, OVS-CNI, KubeVirt → apply
`manifests.yaml` → wait for both VMs → run `verify_datapath.sh` → write the
artifacts. A clean run ends in `PASS` with both flow rules showing nonzero
packet counts.

### Run flags

| Command | What it does |
|---|---|
| `./cluster_setup.sh` | Normal run (real KVM). |
| `FRESH=1 ...` | Delete the cluster and rebuild clean. |
| `ALLOW_EMULATION=1 ...` | Proceed on software emulation if KVM is absent. |
| `FORCE_NO_KVM=1 ...` | Test-only: pretend KVM is absent (no hardware change). |
| `SKIP_VERIFY=1 ...` | Stop once the cluster is ready. |

Flags combine, e.g. `FRESH=1 FORCE_NO_KVM=1 ALLOW_EMULATION=1 ./cluster_setup.sh`.

### Hardware virtualization

I ran this on genuine hardware virtualization, and I can prove it rather than
just claim it:

- `kvm_proof.txt` — `/dev/kvm` on both the host and the minikube node.
- `qemu_accel.txt` — the live VM runs with `-accel kvm` (emulation would be `-accel tcg`).

The script checks KVM inside the node (step 1b) and takes the real-KVM path
automatically. On a machine without KVM it stops cleanly with instructions; add
`ALLOW_EMULATION=1` to run on emulation instead, and that run is clearly
labeled (`EMULATION_NOTICE.txt` + a header in the artifacts) so it can't be
mistaken for the real-KVM result.

**To confirm both modes work on one machine** (I did this to be sure): run the
emulation path, then switch back to real KVM. Between switches, delete the VMs
and clear the emulation setting so the next boot picks up the new mode:

```bash
kubectl delete vm vm-alpha vm-beta
kubectl -n kubevirt patch kubevirt kubevirt --type=merge \
  -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":false}}}}'
FRESH=1 ./cluster_setup.sh
```
Then check `qemu_accel.txt` — `-accel kvm` for real, `-accel tcg` for emulation.
(A leftover `useEmulation: true` will keep new VMs on emulation until cleared.)

#### Why the JSON parser

`ovs-ofctl dump-flows` prints plain text, and this OVS build has no native
`--format=json`. So `flows_to_json.py` parses the real text into JSON, and I
keep the raw output in `flows_after.txt` next to it — the JSON always traces
back to the actual command output, nothing hand-written.

#### What it proves

The VMs' OVS interfaces sit on `192.168.100.0/24`, which has no route except
through `br-ovs`, so a successful inter-VM ping has to cross OVS.
`ping_results.txt` shows 0% loss both directions, and `verification_flows.json`
shows the per-source rules with nonzero `n_packets` — real traffic classified
by OVS, not just default-forwarded.

#### Files | Non-Deliverables but important for verification files are stored in /extras

| File | Purpose |
|---|---|
| `cluster_setup.sh` | End-to-end bootstrap + verification. |
| `manifests.yaml` | NAD + two CirrOS VMs; eth1 IPs set at boot via cloud-init. |
| `verify_datapath.sh` | Re-runnable flow-rule + ping + capture. |
| `flows_to_json.py` | Parses `dump-flows` text into JSON. |
| `verification_flows.json` / `flows_after.txt` | Flow evidence (JSON + raw source). |
| `ping_results.txt` | Bidirectional ping, 0% loss. |
| `dpu_offload_concept.md` | Software datapath → BlueField-3 offload shift. |
| `kvm_proof.txt` / `qemu_accel.txt` | Real-KVM evidence. |
| `fdb.txt` | OVS MAC-learning table. |