# OPI internship, hands-on assignment 2

Shridhar Panigrahi

The cloud-native OVS datapath challenge: a KinD cluster running KubeVirt,
Multus and ovs-cni, two CirrOS VMs attached to an Open vSwitch bridge, a
verified ping between them across that bridge, and the story of how this
datapath changes on a BlueField-3 DPU.

## Deliverables

| File | What it is |
|---|---|
| `cluster_setup.sh` | Bootstraps everything: KinD, KubeVirt (emulation), Multus, OVS inside the node, ovs-cni, and the CirrOS container disk. Verified by a clean-room rerun from a blank Docker (log in `evidence/cleanroom_run.log`) |
| `manifests.yaml` | NetworkAttachmentDefinition for the OVS bridge, both VirtualMachines, and the sidecar hook ConfigMap needed for aarch64 emulation |
| `verification_flows.json` | OpenFlow dump parsed to JSON (raw lines preserved), live megaflow samples showing the VM MACs traversing the bridge, native-JSON OVSDB views, and a documented assumption about the suggested but nonexistent `ovs-ofctl --format=json` flag |
| `ping_results.txt` | Raw serial-console output of the VM-to-VM ping over the bridge: 20/20, 0% loss |
| `dpu_offload_concept.md` | Layer-by-layer mapping of this software datapath to a BlueField-3 with vDPA and OVS hardware offload |

## Supporting material

- `notes/troubleshooting.md` - the four problems hit on the way and how each
  was diagnosed and fixed. Environment: Apple-silicon Mac, so emulation
  quirks feature heavily.
- `evidence/` - screenshots (cluster, VMs, live ping from the guest console,
  flow dump), the raw megaflow samples, and the clean-room run log.
- `tools/` - the expect script that drives the in-guest ping over the serial
  console and the script that assembles `verification_flows.json` from the
  live cluster.

## How to reproduce

```sh
./cluster_setup.sh
kubectl apply -f manifests.yaml
# wait for both VMIs to be Running, then watch the boot ping:
kubectl logs -l kubevirt.io=vm=vm-a -c guest-console-log -f
```

Environment assumptions: Docker Desktop with at least ~6 GB available to
containers; no KVM required (KubeVirt runs with useEmulation). On a Linux
host with KVM the sidecar CPU-mode hook and the emulation flag become
unnecessary but should not hurt.
