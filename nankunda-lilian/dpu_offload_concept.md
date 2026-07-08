# From Software OVS to BlueField-3 Hardware Offload

## 1. The software datapath implemented in this exercise

In `manifests.yaml`, each KubeVirt VM gets two interfaces:

- `default` (masquerade) — ordinary pod networking, used for management.
- `ovsnet` (bridge) — attached via Multus to the OVS CNI, which plugs a
  veth/OVS-internal port into the KinD node's network namespace and adds it
  as a port on the host bridge `br-ovs-lab`.

Every packet a VM sends on `ovsnet` follows this path:

1. **virtio-net inside the guest** hands the frame to QEMU.
2. **vhost-net / vhost-user** in the host kernel (or in `virt-launcher`'s
   QEMU process) copies the packet across the guest/host boundary.
3. The frame lands on a **tap/veth port** that OVS CNI has attached to
   `br-ovs-lab`.
4. **`ovs-vswitchd`** (userspace) consults its flow tables. On a flow miss,
   the packet is punted to userspace, matched against the OpenFlow rules
   installed by the controller (or default normal-forwarding), and a
   **megaflow** is cached in the **kernel datapath** (`openvswitch.ko`,
   via the `ovs-dpctl`/`in_kernel` datapath) so subsequent packets in the
   same flow skip the userspace round-trip.
5. The kernel datapath forwards the frame to the destination port (the
   peer VM's tap/veth), and the reverse path repeats vhost-net/virtio-net
   to deliver it to the destination guest.

Every one of those hops consumes **host CPU cycles** — the hypervisor CPU is
doing packet copies, flow lookups, and context switches for every VM's
traffic, in addition to running the VMs themselves. This is exactly the
"software datapath" the assignment asks us to understand before touching
hardware.

## 2. What changes with an NVIDIA BlueField-3 DPU

A BlueField-3 is a SmartNIC/DPU: a PCIe card with its own Arm cores, memory,
and an embedded switch (eSwitch) inside the NIC's ConnectX-7 network
controller. The goal of offloading to it is to remove the host CPU from the
per-packet forwarding path entirely, while keeping the *same* OVS control
plane and the *same* Kubernetes/KubeVirt orchestration model.

### 2.1 switchdev mode and the eSwitch

The NIC is put into **switchdev mode**, which exposes each SR-IOV Virtual
Function (VF) as a matching **VF representor** netdevice on the host/DPU.
OVS attaches to these representors instead of to tap/veth ports. Internally,
the NIC's **eSwitch** is the actual switching hardware; representors are
just control-plane handles that let `ovs-vswitchd` program it using the
standard OVS/OpenFlow model.

### 2.2 TC flower / OVS-DOCA hardware offload

Instead of every flow being processed by the Linux kernel datapath on the
host CPU, `ovs-vswitchd`'s offload path (via `tc flower`, or natively via
**OVS-DOCA** on BlueField-3) pushes the matched flow's match+action rule
directly into the **NIC's flow tables (ASIC/eSwitch)**. From that point on:

- The **first packet** of a new flow still takes the "slow path" (kernel or
  DOCA control plane) to establish the rule — same as software OVS.
- **All subsequent packets** in that flow are switched entirely **inside
  the NIC hardware**, VF-to-VF or VF-to-uplink, without ever touching the
  host CPU, host PCIe-to-memory copies for switching purposes, or the
  hypervisor's OVS kernel module.

This is the same "flow cache after first miss" pattern seen in step 4
above, except the cache now lives in silicon instead of in
`openvswitch.ko`.

### 2.3 vDPA: moving virtio emulation into hardware too

Separately from switching, **vDPA (virtio Data Path Acceleration)** removes
the second CPU cost: emulating the virtio-net device itself. Instead of
QEMU's vhost-net/vhost-user threads shuttling descriptors between guest
memory and a software switch port, a **vDPA-capable NIC** implements the
virtio-net **data plane** (rings, descriptors, DMA) directly in hardware,
while the **control plane** (feature negotiation, live migration state)
stays in software via the vDPA kernel framework or DPDK's vDPA driver. The
VM still sees an ordinary `virtio-net` device — no guest driver changes —
but packet DMA happens directly between guest memory and the NIC, bypassing
vhost-net and the host kernel network stack altogether.

Combined with switchdev/OVS-DOCA offload, the end-to-end path becomes:

```
guest virtio-net ring  <-- DMA -->  BlueField-3 NIC hardware
                                    (vDPA data plane + eSwitch forwarding)
                                              |
                                    wire / peer VF / uplink
```

with the **host CPU only involved in control-plane events**: VF creation,
flow-rule installation on miss, migration orchestration, and telemetry —
not in per-packet forwarding or per-packet virtio emulation.

## 3. What stays the same vs. what changes

| Layer | Software datapath (this exercise) | BlueField-3 / vDPA / switchdev |
|---|---|---|
| K8s orchestration | KubeVirt `VirtualMachine`, Multus, NAD | **Unchanged** — same CRDs, same `NetworkAttachmentDefinition` model |
| CNI | OVS CNI plugging veth/tap into a Linux OVS bridge | OVS CNI (or SR-IOV CNI) plugging **VF representors** into the DPU's OVS instance |
| OVS control plane | `ovs-vswitchd` + kernel datapath module | `ovs-vswitchd` (often running **on the DPU's Arm cores**) programming the **eSwitch/ASIC** via OVS-DOCA or TC flower offload |
| Per-packet forwarding | Host CPU (kernel datapath / userspace slow path) | **NIC hardware** (eSwitch), host CPU only on flow-miss |
| virtio emulation | QEMU + vhost-net on host CPU | **vDPA data plane in NIC hardware**; QEMU/vDPA framework only handles control plane |
| Host CPU utilization for VM networking | Scales with traffic volume (bad for east-west-heavy workloads) | Roughly flat regardless of traffic volume — freed up for compute workloads |
| Failure/debug surface | `ovs-ofctl dump-flows br0`, standard Linux tools | Same OVS CLI semantics, but flow dumps also need to be read from the DPU/ASIC tables (`ovs-appctl dpctl/dump-flows -m type=offloaded`, DOCA telemetry) |

## 4. Why this matters for the internship's actual goal

The reason to walk through the *software* version first (as this assignment
does) is that the control-plane model — Kubernetes CRDs, Multus attaching
a secondary network, OVS as the switching abstraction, OpenFlow-style flow
tables — is **identical** whether the datapath underneath is a Linux kernel
module on a general-purpose CPU or an ASIC eSwitch on a BlueField-3. Moving
to hardware offload is a *datapath* substitution, not an *architecture*
rewrite: the same `ovs-ofctl dump-flows` mental model applies, just now some
(eventually most) of those flows say `offloaded:true` and live in silicon
instead of in host kernel memory.
