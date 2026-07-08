# OPI internship, hands-on assignment 2

Shridhar Panigrahi

## The result in three sentences

Two CirrOS virtual machines run under KubeVirt on a KinD cluster and attach
to an Open vSwitch bridge through Multus and ovs-cni; a ping between them
crosses the bridge at 20/20 packets, captured raw from the guest's serial
console. The OVS evidence includes live datapath megaflows recorded during
the ping, with the guests' MAC addresses visible traversing the bridge
ports. The whole stack was rebuilt from a deleted cluster by the submitted
script alone - the shipped artifacts come from that clean-room run.

Everything ran on an Apple-silicon laptop with no KVM, which is why the
troubleshooting notes feature emulation quirks so heavily.

## Deliverables

| File | What it is |
|---|---|
| `cluster_setup.sh` | Bootstraps everything: KinD, KubeVirt (emulation mode), Multus, OVS inside the node, a corrected ovs-cni manifest, and the CirrOS container disk for the host architecture |
| `manifests.yaml` | The OVS NetworkAttachmentDefinition, both VirtualMachines with cloud-init static IPs, and the sidecar hook that resolves the aarch64 emulation CPU-mode conflict |
| `ping_results.txt` | Raw guest serial-console output: 20/20 packets VM to VM across the bridge |
| `verification_flows.json` | The OpenFlow dump parsed to JSON with raw lines preserved, live megaflow samples from during the ping, native-JSON OVSDB views - and a documented assumption: the assignment's suggested `ovs-ofctl --format=json` flag does not exist in OVS 3.5.0 |
| `dpu_offload_concept.md` | Layer-by-layer mapping of this software datapath to a BlueField-3 with vDPA, eSwitch representors and OVS-DOCA, with an honest-limits section |

## What is verified, and how

The setup script was proven by a clean-room rerun: cluster deleted, images
deleted, script executed cold, VMs deployed from `manifests.yaml`, ping
observed again (rerun log: `evidence/cleanroom_run.log`). A CI workflow
checks the script's syntax and every machine-readable file on each push.

## Supporting material

- `notes/troubleshooting.md` - the four problems hit while building this and
  how each was diagnosed: an upstream ovs-cni manifest bug, a Docker Desktop
  jumbo-MTU tap failure, the aarch64 emulation catch-22, and the missing
  JSON flag. The debugging is half the value of the exercise.
- `evidence/` - screenshots (cluster, VMs, live ping from the guest console,
  flow dump), the raw megaflow samples, and the clean-room rerun log.
- `tools/` - the expect script that drives the in-guest ping over the serial
  console and the script that assembles `verification_flows.json` from the
  live cluster.

## How to reproduce

```sh
./cluster_setup.sh
kubectl apply -f manifests.yaml
# wait for both VMIs to be Running, then watch the boot-time ping:
kubectl logs -l kubevirt.io/vm=vm-a -c guest-console-log -f
```

Docker Desktop with roughly 6 GB available is enough; no KVM is required.
On a Linux host with KVM the emulation workarounds become unnecessary but
do not interfere.
