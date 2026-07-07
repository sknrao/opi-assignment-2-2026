# Architectural Shift: Software OVS to BlueField-3 Hardware Offload

This document explains how the software datapath deployed for this
assignment - KubeVirt, Multus, ovs-cni, kernel OVS on `br0` - would
change if the same VM's networking moved onto an NVIDIA BlueField-3 DPU
using vDPA and hardware offload. It is a conceptual design, based o
NVIDIA's documented BlueField-3 architecture (switchdev mode, VF
representors, OVS-DOCA, DOCA Flow offload, vDPA)

## Overview

Right now every packet the VM sends is handled by the host's own CPU.
The hypervisor, the kernel network stack, and OVS all run as software,
sharing the same processor that is also running everything else on the
machine. A DPU offloads that work onto a second, smaller computer that
sits on the same PCIe card. It has its own CPU cores and its own
dedicated switching silicon, so the host CPU stops acting as a traffic
cop and goes back to just running VMs.

```
 SOFTWARE DATAPATH (deployed)          BLUEFIELD-3 OFFLOAD (concept)
 ---------------------------          ------------------------------
 cirros-vm                             cirros-vm (guest)
 eth0 pod, eth1 ovs-net                virtio-net, unmodified
      |                                     |
      v                                     v
 KubeVirt                              vDPA-backed VF
 VM lifecycle management               hardware DMA, no host CPU
      |                                     |
      v                                     v
 Multus CNI                            VF representor
 attaches secondary interfaces         netdev on DPU cores
      |                                     |
      v                                     v
 ovs-cni plugin                        OVS-DOCA control plane
 connects vNIC to bridge  --offload-->  runs on DPU cores
      |                                     |
      v                                     v
 OVS bridge br0                        BlueField eSwitch (ASIC)
 runs in host kernel                   hardware line-rate forwarding
      |                                     |
      v                                     +---> Host CPU: bypassed entirely
 Host network stack                         |
 Linux routing and bridging                 v
      |                                Physical network
      v
 Physical NIC
```

## Current Software Datapath

Packet by packet, the deployed stack looks like this:

```
[CirrOS VM: virtio-net eth1]
        |  (vhost-net / QEMU virtio backend, on host CPU)
[virt-launcher pod: tap/pod interface]
        |  (veth pair, created by ovs-cni + Multus)
[OVS internal port on br0]
        |  (kernel datapath lookup, ovs-vswitchd control plane)
[br0 bridge: flow table, actions=NORMAL]
        |
[Physical/host NIC or another pod]
```

| Hop | Where | What happens |
|---|---|---|
| 1 | Guest | virtio-net driver writes a descriptor into the TX ring |
| 2 | Guest - host | descriptor doorbell triggers a VM exit into KVM |
| 3 | Host kernel | vhost-net thread wakes up, reads the ring, copies the packet into a socket buffer |
| 4 | Host kernel | skb enters the network stack via the TAP device |
| 5 | Host kernel | `openvswitch.ko` does a flow table lookup on the skb |
| 6 | Host kernel/userspace | on a cache miss, an upcall goes to `ovs-vswitchd`, which matches OpenFlow tables and installs a kernel cache entry - this is the single `actions=NORMAL` rule seen in `verification_flows.json` |
| 7 | Host kernel | the `NORMAL` action does the L2 lookup and forwarding decision |
| 8 | Host kernel | skb is queued to the physical NIC's TX ring and DMA'd out |

Every one of those eight hops runs on the host CPU, for every one of
the 102 packets counted on that flow. On the hardware side this
collapses to two steps: the ASIC DMA-reads the descriptor and payload
straight out of guest memory, does a hardware flow table lookup, and
transmits - the host CPU is touched nowhere in that sequence.

## BlueField-3 Architecture Overview

A BlueField-3 is one PCIe device with three separate pieces of hardware
bolted together:

1. A **ConnectX-7 NIC ASIC** - physical ports plus an embedded switch
   (the "eSwitch") that matches and forwards packets in silicon.
2. **Sixteen Arm cores** running a full independent Linux install
   (NVIDIA's DOCA/BlueField OS) - effectively a second server sitting
   between the network and the host, reachable over PCIe but not part
   of the host's kernel.
3. Fixed-function blocks for crypto and pattern matching, separate from
   the other two.

From the host's point of view none of this is visible - it looks like a
normal PCIe NIC that happens to have a whole computer running on it.

## Switchdev Mode, SR-IOV VFs, and Representors

Ordinary NIC mode leaves the Arm cores mostly idle. **Switchdev mode**
turns the card's ports into an internal hardware switch that the
Arm-side OS can program. Once switchdev is on, the physical port is
split into SR-IOV VFs, one per VM - the same mechanism any SR-IOV
NIC supports. Each VF gets a matching **representor** netdevice, but
that representor lives on the DPU's own Arm-side Linux, not on the
host's kernel.

`ovs-vswitchd`, also running on those Arm cores, attaches its bridge to
the representors, analogous to how ovs-cni attached to veth ports on
`br0` in the deployed setup:

```
br0 (OVS running ON the DPU's arm cores, not the host)
 |-- uplink representor (the physical port)
 |-- pf0vf0 representor  <-->  VF0  <-->  VM1 (attached via vDPA)
 |-- pf0vf1 representor  <-->  VF1  <-->  VM2
 `-- ...
```

The CLI tools don't change: `ovs-vsctl`, `ovs-ofctl`, the same
OpenFlow/OVSDB model - just running on a smaller, separate Linux
box instead of the host.

## Hardware Flow Offload with OVS-DOCA

NVIDIA's build of OVS for this is **OVS-DOCA**, running on the DPU's own
OS. Its bridge and flow table behave the same way `ovs-ofctl dump-flows
br0` did on the deployed setup - what's different is what happens after
a flow decision gets made.

A new flow's first packet or two still takes the slow path: it shows up
at the physical port, hardware has no rule for it, so it's punted to the
representor and `ovs-vswitchd` on the Arm cores decides where it should
go - the same logic behind the `actions=NORMAL` entry captured above.
Instead of only caching that decision in a kernel software table, the
rule gets pushed straight into the eSwitch's hardware flow tables,
either through TC flower offload or natively via OVS-DOCA's DOCA Flow
API. After that, every packet in that flow is matched and forwarded
entirely by the ASIC - it never touches the Arm cores or the host CPU.
The policy hasn't changed; only what executes it has.

## vDPA and VM Networking

In the deployed setup, the VM's virtio-net is backed by QEMU's
`vhost-net`, a host-CPU thread that emulates the virtio rings and
copies packets between guest memory and the kernel network stack.

With vDPA, the guest still sees an ordinary virtio-net PCI device -
CirrOS or otherwise, zero driver changes. But the virtio queues are
implemented in hardware instead of emulated by QEMU. The DPU hands out
a vDPA-capable VF, the virtio descriptor rings map directly between
guest memory and the NIC, and the ASIC DMAs packets straight in and out
of guest memory. No host CPU thread doing the copy, no QEMU in the data
path - compare that to the actual deployment, where `virt-launcher`'s
QEMU process and the kernel OVS path were both consuming host cycles
for every one of those 102 packets.

## Comparison with the Deployed Stack

| Layer | Deployed stack (verified) | BlueField-3 / vDPA (concept) |
|---|---|---|
| Secondary network attach | ovs-cni + Multus, veth into kernel OVS `br0` | SR-IOV CNI (or ovs-cni hw-offload mode), VF bound via vdpa |
| VM's network device | virtio-net via QEMU/vhost-net | virtio-net via vDPA-backed VF, guest unchanged |
| What actually forwards packets | Linux kernel OVS datapath, host CPU | ASIC eSwitch on the DPU |
| Where OVS's control plane runs | Host CPU | DPU's Arm cores |
| Flow programming | Kernel datapath cache (1 flow, `NORMAL`, seen in `verification_flows.json`) | TC flower / DOCA Flow into hardware tables |
| Host CPU cost per packet | Every packet (all 102 counted) | First packet of a flow, then nothing |

KubeVirt still runs the VM the same way. Multus still hands out the
secondary interface. `manifests.yaml` doesn't change shape in any
fundamental sense - what changes is which physical thing is actually
pushing the bytes underneath it.

## Challenges of Hardware Offload

**Live migration.** With the software stack, a VM's network state lives
in two easy-to-serialize places: the guest's own virtio ring memory, and
OVS's flow table on the host. KubeVirt can copy guest memory to a
destination node and reinstall flows there without much drama. With
vDPA, the virtio rings are DMA-mapped directly into the DPU's ASIC, so
the state that needs to move spans guest memory, the ASIC's internal
flow/conntrack state, and the OVS-DOCA control plane on the DPU's Arm
cores. The source DPU can still be actively DMA'ing into a ring page
while that same page is mid-copy to the destination - a real race
condition. Handling it correctly means quiescing the source DPU's DMA
engine before the final copy, draining in-flight packets from the ASIC
pipeline, and re-establishing the vDPA context on the destination before
the guest resumes, in that order. None of that is needed in the pure
software case.

**Failure behavior.** If `ovs-vswitchd` crashes on the host today, the
kernel datapath keeps forwarding whatever flows are already cached, so
traffic doesn't stop immediately. If the DPU's ASIC hits an error, there
is no equivalent fallback - the NIC is gone for every VM on that host
until the card recovers or is replaced. Concentrating the whole datapath
onto one PCIe card concentrates the failure domain onto that card too.

**Observability.** Once a flow is offloaded into hardware, `tcpdump` and
eBPF/XDP tracing on the host cannot see that traffic - the packets never
enter the host kernel. `ovs-ofctl dump-flows` still works but only shows
control-plane flows unless hardware counters are explicitly polled
through DOCA's own telemetry tooling. Debugging a hardware-offloaded
path means learning vendor-specific tools, not reusing the Linux
networking tools already familiar from the software stack.

## Summary

Moving to BlueField-3 doesn't touch the logical model built here: Multus
still attaches the secondary interface, OVS still owns the bridge and
flow table, KubeVirt still runs the VM. What moves is where OVS's
control plane actually executes (the DPU's Arm cores instead of the
host) and where packets get switched (ASIC hardware tables instead of
the host kernel, replacing the single `NORMAL` software flow seen in
this deployment with per-flow hardware entries). The host CPU stops
doing networking almost entirely, while the tooling used to manage it -
`ovs-vsctl`, `ovs-ofctl`, OVSDB - stays exactly the same, just pointed
at a device that runs its own hardware switch.