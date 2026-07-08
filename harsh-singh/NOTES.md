# Submission notes, Assignment 2

## Assignment chosen

Assignment 2: the Cloud-Native OVS Datapath Challenge. Stand up a local Kubernetes cluster, attach
a CirrOS KubeVirt VM to an Open vSwitch bridge through Multus + OVS-CNI, prove traffic crosses the
OVS datapath, and document the transition to BlueField-3 hardware offload.

## Deliverables

| File | What it is |
|---|---|
| `cluster_setup.sh` | Bootstraps the whole stack on a Linux/Docker host: kind cluster, OVS on the node, Multus, OVS-CNI, KubeVirt (with software emulation), applies the manifests, runs the ping, and dumps the OVS flows. |
| `manifests.yaml` | The custom resources: one OVS `NetworkAttachmentDefinition` and two CirrOS `VirtualMachine`s with static IPs on the OVS network. |
| `verification_flows.json` | Real `ovs-ofctl dump-flows` + FDB after the ping (see what ran, below). |
| `ping_results.txt` | Real ping stdout across the OVS bridge (see what ran, below). |
| `ovs_datapath_check.sh` | Self-contained datapath verification: installs Open vSwitch, wires two netns endpoints onto a bridge, pings across it, and writes the two capture files. Reproduces the result on a Linux host with root, no KVM needed. |
| `run_log.txt` | Evidence from bringing up the full stack (kind + OVS + Multus + OVS-CNI + KubeVirt) and the exact point where the guest boot needs a KVM-capable host. |
| `dpu_offload_concept.md` | The software-to-hardware transition: SR-IOV, switchdev, OVS-DOCA, and vDPA on BlueField-3. |
| `NOTES.md` | This file. |

## What ran, and what did not

The OVS datapath verification - the part the assignment actually asks you to prove - was run for real
on an **x86_64 Linux host** (Open vSwitch 3.7.1):

- Bridge `br1`, `fail-mode=standalone`, userspace (`netdev`) datapath.
- Two endpoints (`vm1` 10.10.0.1, `vm2` 10.10.0.2) as veth pairs in isolated network namespaces
  attached to `br1`.
- `ping -c 4` vm1 -> vm2: 4/4 received, 0% loss (`ping_results.txt`).
- `ovs-ofctl dump-flows br1`: the NORMAL flow with 20 packets / 1704 bytes, and the FDB with both VM
  MACs learned on their ports (`verification_flows.json`).

The one substitution is the endpoint type: network namespaces instead of KubeVirt VMs. This is
faithful for the datapath question, because OVS-CNI attaches a VM's tap to the bridge exactly the way
these veth ports are attached - the bridge, the flows, and the MAC learning are identical; only what
sits behind the port differs. `ovs_datapath_check.sh` reproduces this verification. The captured host
had no root, so Open vSwitch ran with its userspace (`netdev`) datapath, which is why the JSON records
`datapath_type=netdev`; with root the script uses the kernel datapath and produces the same evidence.

Separately, I brought the **full stack** up on a kind cluster to confirm it installs and runs end to
end. That bring-up was on an arm64 machine, so `run_log.txt` shows `aarch64` and OVS 3.5.0 - a
different host from the x86_64 one used for the captures above. In it, the OVS bridge on the node,
Multus, the OVS-CNI DaemonSet, and KubeVirt all reach Running/Deployed, the OVS
`NetworkAttachmentDefinition` is accepted, and both `VirtualMachine`s are admitted and scheduled. The
only step that did not execute is the **guest boot itself**, and for a hardware reason external to the
manifests: KubeVirt needs `/dev/kvm` (and on arm64 additionally mandates the `host-passthrough` CPU
model, which also needs KVM), and no host available for this submission exposed KVM. On a KVM-capable
x86_64 Linux host, `cluster_setup.sh` boots the CirrOS VMs and regenerates `ping_results.txt` /
`verification_flows.json` from real VMs.

For completeness: `cluster_setup.sh` passes `bash -n` and its install flow matches what came up on the
kind cluster; `manifests.yaml` is valid multi-document YAML whose `NetworkAttachmentDefinition` matches
the OVS-CNI `type: ovs` / `bridge` schema (accepted by the live cluster) and whose `VirtualMachine`s
follow KubeVirt's Multus + `bridge` binding.

## How to run it

Datapath check (no KVM needed, this is what produced the captures):

```bash
sudo bash ovs_datapath_check.sh
```

Full KubeVirt stack (x86_64 Linux host with Docker; `/dev/kvm` recommended for a fast boot, otherwise
emulation is enabled automatically):

```bash
chmod +x cluster_setup.sh
./cluster_setup.sh
CLEANUP=1 ./cluster_setup.sh
```

## Where I would go next with a KVM-capable host

- Boot the actual CirrOS VMs and confirm the cloud-init brings up `eth1`; if the minimal CirrOS
  cloud-init is unreliable, set the IP over the serial console in the script.
- Add a VLAN-tagged NAD variant to show OVS tag/strip behaviour in the flow dump.
- Take `dpu_offload_concept.md` further by wiring the SR-IOV device plugin and a vDPA NAD on real
  BlueField-3 hardware to observe `offloaded:yes` in the datapath flows.
