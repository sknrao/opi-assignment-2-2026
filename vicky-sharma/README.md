# Assignment 2, The Cloud-Native OVS Datapath Challenge

**Candidate:** Vicky Sharma · github.com/vickysharma-prog
**Assignment:** https://github.com/sknrao/opi-assignment-2-2026

## What this is
A local Kubernetes lab that runs a **KubeVirt VM on an OVS-backed secondary network**, proves the
datapath with a real ping + OVS flow dump, and documents the shift to **BlueField-3 vDPA hardware
offload**.

**Topology:** k3s (single node) + a **native host OVS bridge** (`br-ovs`) + Multus CNI + OVS-CNI +
KubeVirt. OVS runs directly on the node, so the datapath we observe is real, not hidden inside a
nested container runtime. (This is the "configure a host OVS bridge" path the assignment allows.)

## Deliverables (exact filenames required)
| File | What it is |
|---|---|
| `cluster_setup.sh` | Executable bash: OVS (userspace) -> k3s -> Multus -> OVS-CNI -> KubeVirt, with the k3s CNI-path fixes. `verify` subcommand runs the ping + flow dump. **This is the exact procedure that ran.** |
| `manifests.yaml` | Multi-doc YAML: `NetworkAttachmentDefinition` (ovs-cni) + two CirrOS `VirtualMachine`s (the target) + two verification pods on the same OVS net. |
| `verification_flows.json` | **Real** OVS flows captured live from the running VM's traffic: 1 OpenFlow flow + 5 datapath megaflows (ARP + ICMP, per-flow packet counters), raw text preserved. Serialized to JSON (OVS 3.x `ovs-ofctl` has no `--format=json`). |
| `ping_results.txt` | **Real** ping stdout, `pod-b` (10.10.0.2) -> KubeVirt VM `vm-a` (10.10.0.1), 10/10 packets, 0% loss, over `br-ovs`. |
| `vm_console_boot.txt` | **Real** serial-console boot log of the KubeVirt VM `vm-a`: CirrOS boots to a login prompt and cloud-init self-assigns `eth1=10.10.0.1` on the OVS net. Proof the VM is genuine and its MAC matches the OVS flows. |
| `dpu_offload_concept.md` | Software -> hardware (BF3 vDPA / OVS-DOCA / switchdev) datapath shift, with diagrams + how to prove offload is real. |

Supporting: `ASSUMPTIONS.md`.

## How to run
```bash
chmod +x cluster_setup.sh
./cluster_setup.sh                    # bootstrap the whole stack
kubectl apply -f manifests.yaml       # deploy the OVS network + two CirrOS VMs
./cluster_setup.sh verify             # ping + dump flows -> writes ping_results.txt + verification_flows.json
```
Pinned versions: KubeVirt v1.8.4 · Multus v4.3.0 · OVS-CNI v0.39.0 · k3s v1.36.2. No `/dev/kvm`?
The script auto-enables KubeVirt software emulation (CirrOS still boots; slower).

## Status
Environment: **Ubuntu Linux, single-node k3s** (OVS userspace datapath + Multus + OVS-CNI +
KubeVirt v1.8.4). **A real KubeVirt VM was booted and the OVS datapath verified with live-captured
output.** The CirrOS `VirtualMachine` `vm-a` reached `phase=Running` and self-assigned `10.10.0.1`
on its OVS interface (`vm_console_boot.txt`); a peer pod `pod-b` (10.10.0.2) pinged it across
`br-ovs`, `ping_results.txt` (10/10 packets, 0 % loss), and `verification_flows.json` shows the
ARP + ICMP datapath flows (9 echo requests + 9 replies) with the VM's own MAC. This is the host-OVS
path the assignment explicitly allows ("configure a host OVS bridge"). See `ASSUMPTIONS.md` for the
environment, the three k3s CNI fixes, and design decisions.

## The design in one paragraph
`ovs-cni` plugs the VM's `bridge`-bound interface into a port on the host OVS bridge `br-ovs`.
A ping between `vm-a` (10.10.0.1) and a second `ovs-net` endpoint (10.10.0.2) therefore traverses
`br-ovs`, and `ovs-ofctl dump-flows br-ovs` shows the flows. On BlueField-3 the *same* control plane
stays put while the datapath moves into the DPU eswitch (OVS-DOCA), reached by the guest via vDPA so
it keeps a stock `virtio-net` driver, see `dpu_offload_concept.md`.
