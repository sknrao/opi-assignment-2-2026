# From a Local OVS Lab to a BlueField-3 DPU

## What I built

I built a deliberately small network: one CirrOS virtual machine and one
BusyBox pod share an isolated Open vSwitch bridge named `br-ovs`.

Kubernetes still gives both workloads their normal cluster interface. Multus
adds a second interface, and the OVS CNI connects that interface to `br-ovs`.
The fixed addresses make the test easy to repeat:

| Workload | OVS address | Purpose |
|---|---:|---|
| CirrOS VM | `192.168.100.10` | Destination being tested |
| BusyBox peer | `192.168.100.20` | Source of the ping |

The ping is intentionally local to the OVS network. No physical NIC, Internet
route, or external switch is needed to prove the software datapath.

## Following one packet

The useful mental model is to follow a ping packet one hop at a time:

```text
CirrOS
  │ virtio-net
  ▼
QEMU
  │ tap device
  ▼
Linux bridge inside the virt-launcher pod
  │ pod-side interface
  ▼
veth pair created by OVS CNI
  │
  ▼
br-ovs on the Kubernetes node
  │ another OVS CNI veth
  ▼
BusyBox peer
```

Each layer has a narrow job:

- **KubeVirt** turns the `VirtualMachine` declaration into a QEMU process.
- **virtio-net** is the network device seen by the guest.
- **The tap and Linux bridge** connect QEMU to the pod network namespace.
- **Multus** asks for an additional network alongside the ordinary pod network.
- **OVS CNI** creates the veth and adds its host end to `br-ovs`.
- **Open vSwitch** learns MAC addresses and forwards the Ethernet frames.

This is a software datapath. Packet handling, virtual switching, interrupts,
and memory copies all consume general-purpose CPU time. That is perfectly fine
for a learning environment, but it is the work we want a DPU to absorb at
scale.

## What the captured flows prove

The script installs two high-priority ICMP rules: one for the echo request and
one for the reply. Both use the normal OVS learning-switch action.

```text
192.168.100.20 → 192.168.100.10  actions=NORMAL
192.168.100.10 → 192.168.100.20  actions=NORMAL
```

After the ping, both rules must have non-zero packet counters. This is stronger
evidence than merely showing that two ports exist: it demonstrates that OVS
classified traffic in both directions.

## What changes on BlueField-3

The Kubernetes intent does not disappear. KubeVirt still defines a VM, Multus
still selects a secondary network, and a device plugin still advertises
allocatable networking resources. The main change is *where the packet work
happens*.

```text
Local lab                              BlueField-3 target
---------                              ------------------
Guest virtio-net                       Guest virtio-net
       │                                      │
QEMU tap + host software bridge        vhost-vDPA device
       │                                      │ DMA
host veth                              BlueField hardware virtqueue
       │                                      │
software OVS on host CPU               embedded e-switch
                                              │
                                       OVS-DOCA offloaded rule
                                              │
                                       physical port / representor
```

The guest deliberately continues to see a standard virtio device. That is a
valuable compatibility boundary: the acceleration can change without teaching
the guest operating system about BlueField hardware.

### 1. Switchdev exposes the hardware switch

In switchdev mode, the BlueField embedded switch (the **e-switch**) is
controlled through Linux networking interfaces. Physical functions, virtual
functions, and scalable functions have **representor** interfaces.

A representor is best understood as the software control point for a hardware
port. OVS attaches representors to its bridge and programs forwarding rules
between them. The representor is visible to software, but an offloaded packet
does not need to travel through the Arm CPU for every hop.

### 2. OVS-DOCA moves matching and actions into hardware

OVS remains the switching control plane, so familiar bridges, ports, OpenFlow
rules, and counters remain useful. On the DPU, OVS-DOCA translates supported
OVS actions into DOCA Flow rules for the BlueField hardware.

The important settings are conceptually:

```bash
ovs-vsctl --no-wait set Open_vSwitch . other_config:doca-init=true
ovs-vsctl set Open_vSwitch . other_config:hw-offload=true
```

OVS must then be restarted as required by the installed DOCA release. Exact
port names and startup commands depend on the BlueField image and whether the
deployment uses the kernel or userspace OVS datapath.

The first packets of a new flow can still involve software while OVS decides
what to install. Once a supported rule is offloaded, later packets follow the
hardware fast path. Unsupported actions must be detected because they can fall
back to software and quietly remove the expected performance benefit.

### 3. vDPA shortens the VM I/O path

**vDPA** means *virtio data path acceleration*. A vDPA management driver creates
a device, and Linux exposes a character device such as
`/dev/vhost-vdpa-0`. QEMU uses that device as the backend for the guest's
virtio-net interface.

The control plane still negotiates virtio features and configures queues, but
packet buffers are transferred between guest memory and BlueField hardware
using DMA. This removes the tap/veth/software-switch path from steady-state
packet processing.

In Kubernetes, a device plugin would advertise the vDPA resource. The Multus
network definition would request that resource, and the KubeVirt integration
would pass the matching vhost-vDPA device into the VM launcher. The exact CNI
and binding resources are deployment-specific and must match the NVIDIA
Network Operator and DOCA versions selected for the cluster.

### 4. DMA requires isolation, not just speed

Allowing a device to access guest memory makes IOMMU configuration part of the
design, not an optional tuning detail. The IOMMU constrains DMA to memory owned
by the assigned VM. Queue ownership, device lifecycle, NUMA placement, and
cleanup after a VM exits must also be verified.

## Software and offloaded paths side by side

| Question | Local software lab | BlueField-3 design |
|---|---|---|
| What does the guest see? | virtio-net | virtio-net |
| VM backend | QEMU tap | vhost-vDPA device |
| Switch execution | Host CPU | BlueField e-switch |
| OVS location | KinD node | DPU Arm environment |
| OVS port type | CNI-created veth | PF/VF/SF representor |
| Flow programming | OVS software datapath | OVS-DOCA to DOCA Flow |
| Data movement | CPU copies and kernel/userspace work | DMA and hardware queues |
| Slow-path fallback | Normal behavior | Important condition to detect |

## How I would verify the real DPU

I would verify the system layer by layer, just as the local script does.

### Device and switch mode

```bash
devlink dev show
devlink dev eswitch show pci/0000:03:00.0
ip -d link show
```

Expected result: the correct PF is in `switchdev` mode and its representors are
visible and up. The PCI address is only an example; the real address must be
discovered on the DPU.

### vDPA device

```bash
vdpa dev show
ls -l /dev/vhost-vdpa-*
```

Expected result: the allocated vDPA device maps to the intended VM resource,
and the corresponding character device is present inside the launcher
environment.

### OVS and hardware offload

```bash
ovs-vsctl show
ovs-vsctl get Open_vSwitch . other_config:hw-offload
ovs-appctl dpctl/dump-flows type=offloaded
ovs-ofctl -O OpenFlow13 dump-flows br-ovs
```

Expected result: representors are on the intended bridge, hardware offload is
enabled, and the tested flow appears as offloaded with increasing counters.
Representor statistics from `ethtool -S <representor>` provide another useful
cross-check.

### End-to-end behavior

I would repeat the same ping first, then add throughput and latency tests.
Success means more than connectivity: hardware counters must rise while host
and DPU CPU use stays consistent with an offloaded fast path.

## Troubleshooting decision tree

```text
Can the VM see its second interface?
├─ No → check KubeVirt device assignment and vDPA resource allocation
└─ Yes
   └─ Is the vDPA device and /dev/vhost-vdpa-* node present?
      ├─ No → check driver binding, device plugin, and permissions
      └─ Yes
         └─ Are representors attached to the expected OVS bridge?
            ├─ No → check switchdev mode and representor mapping
            └─ Yes
               └─ Does ping work?
                  ├─ No → inspect MAC learning, VLANs, MTU, and OVS flows
                  └─ Yes
                     └─ Is the flow reported as offloaded?
                        ├─ No → find unsupported actions or DOCA errors
                        └─ Yes → confirm hardware counters and performance
```

This ordering matters. A successful ping does not prove hardware offload, and
an OVS rule does not prove that the VM received the correct vDPA device.

## What was demonstrated and what remains conceptual

Demonstrated locally:

- Kubernetes orchestrating a VM and a container.
- Multus adding a secondary interface.
- OVS CNI attaching both workloads to an OVS bridge.
- Bidirectional ICMP traffic counted by explicit OVS flows.
- Reproducible, machine-readable evidence.

Not demonstrated without physical hardware:

- BlueField switchdev and representor creation.
- OVS-DOCA rule installation.
- vDPA device allocation to KubeVirt.
- DMA/IOMMU isolation.
- Performance improvement and software-fallback behavior.

Keeping that boundary explicit is important. The local lab proves my
understanding of the plumbing; it does not pretend to prove hardware behavior
that was never exercised.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| No KVM acceleration | Use software emulation for functional testing, but use a KVM-capable Linux node before drawing performance conclusions. |
| ARM/TCG CPU compatibility | Detect the host architecture and choose a CPU model that QEMU's software emulator supports. Keep this workaround limited to local development. |
| MTU mismatch | Use the same MTU across KinD, tap, veth, and OVS interfaces, then verify it at each layer if traffic is dropped. |
| Guest interface configuration | Configure the CirrOS secondary NIC explicitly and wait until its address is reachable before starting verification. |
| Version compatibility | Pin versions that have been tested together and check KubeVirt, CNAO, Multus, OVS CNI, and OVS independently during setup. |
| Privileged node modification | Perform OVS installation and node-network changes only in an isolated development cluster. Use controlled node preparation and least privilege in production. |
| Local test is not hardware-offload proof | Treat the local result as software-datapath evidence. On BlueField-3, separately verify switchdev, representors, vDPA devices, and hardware counters. |
| Silent software fallback | Check that flows are reported as offloaded and confirm that hardware counters increase during traffic instead of relying on connectivity alone. |
| DMA/IOMMU isolation | Enable IOMMU, verify device-to-VM mappings, restrict device ownership, and use supported firmware and drivers. |
| Evidence is environment-specific | Regenerate ping and flow evidence for each deployment and require live, non-zero counters instead of relying on saved interface names or old results. |

## Lessons learned and next steps

The most useful lesson is that “the VM is connected” is only the beginning.
There are several independently testable layers: orchestration, secondary
interface creation, OVS port attachment, flow classification, and finally
hardware offload.

On a real BlueField-3 system, my next steps would be:

1. Record firmware, DOCA, driver, Kubernetes, and KubeVirt versions.
2. Confirm DPU mode, switchdev, IOMMU, and representors before deploying a VM.
3. Install the NVIDIA device and network operators with version-matched vDPA
   components.
4. Allocate one vDPA resource to a minimal VM and verify its virtio queues.
5. Reproduce the ping while correlating guest, OVS, representor, and hardware
   counters.
6. Test an intentionally unsupported rule to understand fallback behavior.
7. Measure latency, throughput, CPU use, and recovery after VM recreation.

## References

- [KubeVirt interfaces and secondary networks](https://kubevirt.io/user-guide/network/interfaces_and_networks/)
- [Kubernetes Network Plumbing Working Group OVS CNI](https://github.com/k8snetworkplumbingwg/ovs-cni)
- [NVIDIA OVS-DOCA hardware acceleration](https://docs.nvidia.com/doca/archive/3-0-0/OVS-DOCA%2BHardware%2BAcceleration/index.html)
- [NVIDIA virtual switch on DPU and hardware vDPA](https://docs.nvidia.com/networking/display/bluefielddpubspv403/virtual%2Bswitch%2Bon%2Bdpu)
