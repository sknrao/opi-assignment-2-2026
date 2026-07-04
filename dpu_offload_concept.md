# Architectural Shift: Software OVS to DPU-Accelerated vDPA Offload

This document conceptualizes the transition of our currently implemented software-based Kubernetes/OVS datapath to a fully hardware-accelerated architecture using an NVIDIA BlueField-3 DPU via vDPA (vHost Data Path Acceleration).

---

## 1. The Current Software Datapath (CPU Bound)

In our current implementation (`cluster_setup.sh` + `manifests.yaml`), the entire network datapath is processed by the host CPU.

1. **Traffic Origination:** The KubeVirt VM (guest OS) generates a packet.
2. **Virtio Interface:** The packet traverses the `virtio-net` driver inside the guest, crossing into the host user-space via QEMU.
3. **Host Tap Device:** QEMU pushes the packet to a `tap` interface in the Kubernetes node (e.g., `vnet0`).
4. **OVS Kernel Datapath:** The `tap` interface is attached to `br0` (Open vSwitch). The host CPU processes the packet through the OVS kernel module, matches OpenFlow rules, and switches the packet to the destination.
5. **Egress:** The packet exits out of the physical NIC (eth0) onto the wire.

**Bottlenecks:** Every packet incurs context switches (Guest OS -> QEMU -> Host Kernel -> OVS -> NIC). This consumes significant host CPU cycles, limiting throughput and increasing latency.

---

## 2. The BlueField-3 DPU & vDPA Architecture (Hardware Offload)

Moving to an NVIDIA BlueField-3 DPU fundamentally changes this architecture. The host CPU is entirely bypassed for the data plane. We utilize **vDPA (vHost Data Path Acceleration)** to provide hardware-accelerated SR-IOV performance while maintaining standard `virtio` drivers inside the VM.

### Architectural Changes

#### A. Data Plane Bypass (Hardware Offload)
- Instead of the host CPU running the OVS kernel module, the BlueField-3's embedded eSwitch (Hardware switch) takes over the datapath.
- The physical NIC is placed in **switchdev mode**. This exposes the DPU's eSwitch representor ports to the host OS.
- When an OpenFlow rule is programmed into OVS on the host, **OVS-DOCA** (or OVS hardware offload via TC flower) intercepts it and pushes the rule directly into the ASIC (hardware eSwitch) on the BlueField-3.
- Subsequent packets are switched completely in silicon by the DPU, utilizing 0% of the host x86 CPU.

#### B. vDPA (vHost Data Path Acceleration)
- Traditionally, hardware acceleration required SR-IOV VF (Virtual Function) pass-through, forcing the VM to use proprietary vendor drivers (e.g., `mlx5_core`). This breaks live migration.
- **vDPA solves this.** The VM continues to use the standard, open-source `virtio-net` driver.
- The BlueField-3 DPU acts as a vDPA parent device. It emulates the `virtio` ring layout directly in hardware.
- The KubeVirt VM's memory pages (vRings) are mapped directly via DMA to the DPU hardware.

### 3. The New Packet Journey (vDPA Offload)

1. The KubeVirt VM generates a packet using the standard `virtio-net` driver.
2. The packet is placed directly into the virtqueue memory buffer.
3. **(Host OS and QEMU Bypassed)** The BlueField-3 DPU pulls the packet directly via DMA from the VM's memory buffer.
4. The packet enters the DPU's eSwitch ASIC.
5. The eSwitch ASIC matches the hardware-offloaded OVS rules (programmed previously via switchdev/DOCA) and forwards the packet directly out the physical wire.

### 4. Kubernetes Integration Shifts
To implement this in Kubernetes, the orchestrator stack changes:
- **Multus + OVS CNI:** Replaced or augmented by **Multus + SR-IOV Network Device Plugin** (configured for vDPA).
- The Device Plugin detects vDPA-capable VFs on the BlueField-3.
- When KubeVirt spins up the VM, it mounts the vDPA `vhost-vdpa` character device into the pod rather than creating a software `tap` interface.

### Summary
By migrating to the NVIDIA BlueField-3 with vDPA, we achieve bare-metal hardware switching performance (line-rate 400Gbps) while maintaining the cloud-native flexibility of standard `virtio` drivers inside the Virtual Machines.