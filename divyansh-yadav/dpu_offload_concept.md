# DPU Offload Concept: From Software OVS to BlueField-3 Hardware Datapath

> **Scope note:** Part I and the packet-walk sections describing the software
> OVS baseline are derived directly from the working lab in this assignment
> (KinD + KubeVirt + OVS-CNI, using default parameters: `br-ovs`, VLAN 100)
> and are verifiable against the included setup script and verification
> artifacts. Both the bridge/VLAN/CNI wiring and the VM-level ping
> verification were confirmed against the real KubeVirt-provisioned CirrOS
> guest — no substitute endpoint was required. The guest was reached via
> `virtctl console`, logged in with the CirrOS default credentials, and
> exercised a live bidirectional ping over the OVS secondary interface
> (`eth1`), captured in `ping_results.txt`. This host runs under software
> emulation (TCG, no `/dev/kvm`), which affected boot time but not the
> validity of the result.
>
> Part II onward (BlueField-3 / DOCA / vDPA) describes conceptual,
> industry-standard architecture for hardware-offloaded datapaths and was
> **not** implemented or tested as part of this assignment — no DPU hardware
> was available. These sections are forward-looking architectural analysis,
> not a report of validated results.

**Author:** Divyansh Yadav
**Assignment:** Assignment 2 — The Cloud-Native OVS Datapath Challenge
**Date:** 2026-07-04
**Last Revised:** 2026-07-04
**Classification:** Systems Architecture Reference Document

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Part I — The Baseline: CPU-Bound Software OVS Datapath](#2-part-i)
   - 2.1 [Component Topology](#21-component-topology)
   - 2.2 [Packet Walk: VM Transmit Path (Software)](#22-packet-walk)
   - 2.3 [Performance Profile and Bottlenecks](#23-performance)
3. [Part II — The Hardware Shift: NVIDIA BlueField-3 DPU Architecture](#3-part-ii)
   - 3.1 [What Is a DPU? Conceptual Model](#31-what-is-a-dpu)
   - 3.2 [BlueField-3 Internal Architecture](#32-bluefield-3)
   - 3.3 [Switchdev Mode: Kernel Representor Model](#33-switchdev-mode)
   - 3.4 [OVS-DOCA: The Hardware-Accelerated Control Plane](#34-ovs-doca)
4. [Part III — vDPA: The VM-to-Silicon Direct Path](#4-part-iii)
   - 4.1 [Virtio and Its Limitations](#41-virtio)
   - 4.2 [vHost-user: The Software Fast-Path](#42-vhost-user)
   - 4.3 [vDPA Architecture: Bypass to the DPU](#43-vdpa)
   - 4.4 [Cloud-Native Abstraction Preservation](#44-cloud-native)
5. [Part IV — Full Offloaded Packet Walk](#5-part-iv)
6. [Part V — Architectural Comparison Matrix](#6-part-v)
7. [Part VI — Edge Cases & Trade-offs](#7-part-vi)
   - 7.1 [Live Migration with Hardware Offload](#71-live-migration)
   - 7.2 [Failure Domain Analysis](#72-failure-domain)
   - 7.3 [Control-Plane vs. Data-Plane Split](#73-control-plane)
   - 7.4 [Operational Maturity and Trade-offs](#74-operational-maturity)
8. [Part VII — Kubernetes Integration Architecture](#8-part-vii)
9. [Conclusion](#9-conclusion)
10. [References](#10-references)

---

## 1. Executive Summary

This document describes the architectural shift that occurs when the
virtual machine networking datapath — demonstrated in this assignment using
a software OVS bridge inside a KinD cluster — is offloaded to an **NVIDIA
BlueField-3 Data Processing Unit (DPU)**.

The core transformation is this:

> In the software model, every packet traversing a VM's virtual NIC is
> processed by the host CPU: through QEMU's vhost-net backend, the TAP
> device, the Linux kernel network stack, Open vSwitch's flow-matching
> pipeline, and out the physical NIC. The host CPU is both the compute
> resource *and* the network resource.
>
> In the DPU offload model, the packet **never touches the host CPU after
> leaving the VM's virtio ring**. It is consumed directly by the DPU's
> embedded ASIC, matched against hardware flow tables in the ConnectX-7 NIC
> silicon, and forwarded at line rate. The host CPU is freed entirely from
> datapath work.

This shift enables:

- **Line-rate forwarding** (100–400 Gbps) with negligible CPU overhead
- **Deterministic, jitter-free latency** (sub-microsecond for
  hardware-matched flows)
- **CPU core reclamation** — OVS typically consumes 2–4 dedicated CPU cores
  per server; these are returned to tenant workloads
- **Infrastructure-as-Code** — the DPU runs its own Linux OS and
  Kubernetes-compatible control plane, programmable via the same GitOps
  pipelines as the rest of the cluster

---

<a id="2-part-i"></a>
## 2. Part I — The Baseline: CPU-Bound Software OVS Datapath

<a id="21-component-topology"></a>
### 2.1 Component Topology

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                        HOST KERNEL (x86_64)                             │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                QEMU/KVM Process (virt-launcher pod)              │   │
│  │                                                                 │   │
│  │   ┌──────────────────────────────────────────────────────────┐  │   │
│  │   │                CirrOS VM (Guest OS)                       │  │   │
│  │   │   eth0 (virtio-net) ←──── virtio ring ──── vhost-net      │  │   │
│  │   │   eth1 (virtio-net) ←──── virtio ring ──── vhost-net      │  │   │
│  │   └──────────────────────────────────────────────────────────┘  │   │
│  │              │                           │                        │   │
│  │           tap0 (fd)                  tap1 (fd)                   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│              │                           │                              │
│         ┌────▼────┐                 ┌────▼────┐                        │
│         │  veth0  │                 │  tap1   │  ← virt-handler bridge  │
│         │ (Flannel│                 │ (TAP)   │    to OVS-CNI veth      │
│         │  CNI)   │                 └────┬────┘    on br-ovs            │
│         └─────────┘                      │                             │
│                                    ┌─────▼─────────────────────────┐   │
│                                    │  OVS Kernel Datapath           │   │
│                                    │  (openvswitch.ko)              │   │
│                                    │   ┌──────────────────────────┐ │   │
│                                    │   │  Flow Table (DPIF cache) │ │   │
│                                    │   │  Table 0: NORMAL         │ │   │
│                                    │   │  VLAN 100 tagging        │ │   │
│                                    │   └──────────────────────────┘ │   │
│                                    │              br-ovs             │   │
│                                    └────────────────┬────────────────┘   │
│                                                     │                    │
│                                    ┌────────────────▼────────────────┐   │
│                                    │     Physical NIC (eth0/ens3f0)  │   │
│                                    │     (Kernel netdev stack)       │   │
│                                    └────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
                                              │
                                    ═══════════════════════
                                    Physical Network Fabric
```

<a id="22-packet-walk"></a>
### 2.2 Packet Walk: VM Transmit Path (Software)

When the CirrOS VM sends an ICMP packet on `eth1` (the OVS secondary
interface), the following sequence of CPU operations occurs:

| Hop | Location | Operation | CPU Cost |
|-----|----------|-----------|----------|
| 1 | VM Guest | virtio-net driver places packet in TX virtqueue ring | Guest vCPU |
| 2 | KVM | VM-exit triggered by virtio doorbell kick | Host CPU (trap) |
| 3 | QEMU/vhost-net | vhost-net kernel thread reads virtqueue, copies packet to TAP fd | Host CPU (kernel thread) |
| 4 | TAP device | Packet enters the kernel network stack as an skb | Host CPU (softirq) |
| 5 | OVS netdev layer | skb received by `openvswitch.ko`; triggers flow table lookup | Host CPU (softirq) |
| 6 | OVS DPIF | Kernel datapath cache checked (fast path); cache miss → upcall to vswitchd | Host CPU |
| 7 | ovs-vswitchd | Userspace process matches OpenFlow tables, installs kernel cache entry | Host CPU (userspace) |
| 8 | OVS action | Packet forwarded via `NORMAL` action: L2 MAC lookup, VLAN handling | Host CPU |
| 9 | Physical NIC driver | skb enqueued to NIC TX ring; DMA transfer | Host CPU + NIC DMA |
| 10 | Physical NIC | NIC transmits frame onto the wire | NIC hardware |

**Key observation:** steps 1–9 are all CPU-bound. Every packet — tenant
traffic or infrastructure overhead alike — steals CPU cycles from the host.

<a id="23-performance"></a>
### 2.3 Performance Profile and Bottlenecks

**Throughput ceiling.** Software OVS on a modern server CPU typically
achieves **10–25 Mpps** for small packets — roughly **5–17 Gbps** at 64-byte
frames once framing overhead is included (10 Mpps × 84 B/frame × 8 ≈
6.72 Gbps; 25 Mpps × 84 B × 8 ≈ 16.8 Gbps). For 1500-byte MTU frames,
per-packet overhead is amortized and a tuned OVS-DPDK setup can approach
40–60 Gbps. Either way, this sits far below the 100–400 Gbps line rate of
modern physical NICs.

**CPU consumption.** Full-throughput OVS-DPDK reserves **2–4 dedicated
physical CPU cores** for PMD (Poll Mode Driver) threads. In the kernel-OVS
configuration used in this lab, the host's softirq budget is shared with
other workloads, causing unpredictable latency spikes.

**Upcall cost.** A DPIF cache miss triggers an expensive upcall to
`ovs-vswitchd`, involving a context switch and a Netlink `write()` syscall.
For short-lived flows — common in microservices — the upcall rate can
dominate CPU usage.

**vhost-net copy overhead.** Every packet on the vhost-net path requires at
least one `copy_from_user()`/`copy_to_user()` plus a VM-exit for the virtio
doorbell. For small packets, this per-packet overhead dominates latency.

---

<a id="3-part-ii"></a>
## 3. Part II — The Hardware Shift: NVIDIA BlueField-3 DPU Architecture

<a id="31-what-is-a-dpu"></a>
### 3.1 What Is a DPU? Conceptual Model

A **Data Processing Unit (DPU)** is a third category of programmable
processor, distinct from:

- **CPU** — general-purpose, optimized for serial logic and branch prediction
- **GPU** — massively parallel, optimized for floating-point throughput (SIMD)
- **DPU** — network-centric, optimized for packet classification, tunneling,
  and I/O at line rate

Physically, the NVIDIA BlueField-3 DPU is a **PCIe card**. From the host's
perspective it presents as a NIC, but internally it contains:

- A full **Arm Cortex-A78AE** cluster (16 cores) running its own Linux OS
- The **ConnectX-7 ASIC** — the network processing unit with hardware flow
  tables
- **Hardware accelerators** for cryptography (IPsec, TLS), compression, and
  regex
- A **PCIe switch** creating an infrastructure network isolated from the host

This architecture lets the DPU run the **entire OVS control plane**
independently of the host, while the ConnectX-7 ASIC handles forwarding in
hardware.

<a id="32-bluefield-3"></a>
### 3.2 BlueField-3 Internal Architecture

```text
┌──────────────────────────────────────────────────────────────────────┐
│                    BLUEFIELD-3 DPU (PCIe Card)                       │
│                                                                      │
│  ┌─────────────────────────────────┐   ┌──────────────────────────┐ │
│  │    Arm SoC (DPU OS / DOCA)      │   │   ConnectX-7 ASIC        │ │
│  │                                  │   │                          │ │
│  │  ┌──────────────────────────┐   │   │  ┌────────────────────┐  │ │
│  │  │  OVS-DOCA (control plane)│   │   │  │ Hardware Flow Table │  │ │
│  │  │  ovs-vswitchd (Arm)      │   │   │  │ (TCAM + SRAM)       │  │ │
│  │  │  Flow compilation        │───┼───┼─▶│ Millions of exact-  │  │ │
│  │  │                          │   │   │  │ match (hash) + up   │  │ │
│  │  │                          │   │   │  │ to ~1M TCAM entries │  │ │
│  │  │                          │   │   │  │ (vendor limits)     │  │ │
│  │  └──────────────────────────┘   │   │  └────────────────────┘  │ │
│  │                                  │   │           │              │ │
│  │  ┌──────────────────────────┐   │   │  ┌────────▼───────────┐  │ │
│  │  │  Kubernetes Agent        │   │   │  │  Packet Processor  │  │ │
│  │  │  (DOCA Kubernetes Plugin)│   │   │  │  • Header rewrite   │  │ │
│  │  │  NetworkPolicy enforcer  │   │   │  │  • VLAN push/pop    │  │ │
│  │  └──────────────────────────┘   │   │  │  • VXLAN encap      │  │ │
│  │                                  │   │  │  • Metering/QoS     │  │ │
│  │  ┌──────────────────────────┐   │   │  └────────────────────┘  │ │
│  │  │  Crypto/Compression HW   │   │   │           │              │ │
│  │  │  (IPsec, TLS offload)    │   │   │  ┌────────▼───────────┐  │ │
│  │  └──────────────────────────┘   │   │  │  Network Ports      │  │ │
│  │                                  │   │  │  (2x 400G OSFP)    │  │ │
│  └─────────────────────────────────┘   └──────────────────────────┘ │
│               │                                    │                  │
│        PCIe interface                     Physical network            │
│      (to host server PCIe)               (upstream fabric)           │
└──────────────────────────────────────────────────────────────────────┘
             │
             ▼ PCIe bus
┌────────────────────────────────┐
│    HOST SERVER (x86_64)        │
│    VFs exposed as PCIe devices │
│    Host sees only PCIe VFs     │
│    No NIC driver, no OVS       │
└────────────────────────────────┘
```

<a id="33-switchdev-mode"></a>
### 3.3 Switchdev Mode: Kernel Representor Model

**Switchdev** is a Linux kernel framework (introduced in 4.8, matured in
5.x) that exposes a NIC's hardware switching ASIC to the Linux networking
stack via a software *representor* model.

**The key insight:** in Switchdev mode, physical NIC ports and each SR-IOV
Virtual Function (VF) appear in the host kernel as **representor
netdevs** — lightweight software handles into the hardware. They do not
carry data-plane traffic; they only carry:

- Flow rules (written by ovs-vswitchd on the DPU via `tc flower` /
  `rte_flow` APIs)
- Exception/miss traffic the hardware cannot classify (punted to the DPU's
  Arm cores)

```text
HOST KERNEL VIEW (Switchdev mode):
  eth0_0    ← representor for PF0 (physical port 0)
  eth0_1    ← representor for PF1 (physical port 1)
  eth0_0vf0 ← representor for VF0 of PF0 (attached to VM 1's vDPA device)
  eth0_0vf1 ← representor for VF1 of PF0 (attached to VM 2's vDPA device)
  ...

The host runs NO ovs-vswitchd. The representors are just handles.
Flow rules written to representors are compiled by the ASIC driver
and installed into the ConnectX-7 hardware flow tables.
```

This is powerful because it lets the standard Linux `tc`/`ip` tooling
program hardware at full line rate without knowing anything about the ASIC
internals — the `mlx5` driver translates `tc flower` rules into hardware
TCAM entries.

<a id="34-ovs-doca"></a>
### 3.4 OVS-DOCA: The Hardware-Accelerated Control Plane

**OVS-DOCA** is NVIDIA's production-grade fork of Open vSwitch running on
the BlueField-3's Arm cores. It is architecturally identical to stock OVS
from the control-plane perspective (same OpenFlow 1.3/1.4 API, same OVSDB
schema), but its DPIF (Datapath Interface) layer is replaced with a DOCA
(Data-center Infrastructure-on-a-Chip Architecture) backend.

**DOCA DPIF behavior:**

1. `ovs-vswitchd` on the Arm SoC compiles OpenFlow rules into
   hardware-acceleratable rulesets
2. Rules are pushed to the ConnectX-7 hardware via the **mlx5 PMD** and
   **DOCA Flow API**
3. Matched packets are processed entirely in silicon — zero Arm CPU cycles
   for the fast path
4. Only **exception packets** (first packet of a new flow, control traffic,
   ARP) are punted to the Arm cores for classification

**Slow path — software vs. DPU:**

| Scenario | Software OVS slow path | OVS-DOCA slow path |
|----------|------------------------|---------------------|
| Location | Host x86 CPU (vswitchd) | DPU Arm SoC (vswitchd) |
| Impact on tenant workloads | Steals host CPU cycles | Zero host CPU impact |
| Frequency | Every cache miss (potentially millions/sec) | Only true exceptions |
| Remediation | Cache tuning, DPDK PMD threads | Hardware TCAM sizing |

---

<a id="4-part-iii"></a>
## 4. Part III — vDPA: The VM-to-Silicon Direct Path

<a id="41-virtio"></a>
### 4.1 Virtio and Its Limitations

**Virtio** is the de facto standard paravirtualized I/O interface for VMs.
The virtio-net device presents a split virtqueue model to the guest: a TX
ring and an RX ring of buffer descriptors. The guest writes descriptors; the
host processes them.

The fundamental inefficiency: **every descriptor notification crosses the
VM boundary.** In the software datapath:

- The guest kicks the host via an MMIO write (triggers a VM-exit)
- The host's vhost-net kernel thread wakes and processes the ring
- The host copies the packet to a kernel socket buffer (skb)
- The host kernel network stack takes ownership

This VM-exit-plus-copy chain is the irreducible cost of software-only
virtio.

<a id="42-vhost-user"></a>
### 4.2 vHost-user: The Software Fast-Path

**vHost-user** (used by OVS-DPDK) removes the *kernel* intermediary by
placing the virtio ring in shared memory — but it does not fully eliminate
VM-exits:

- QEMU maps the guest's virtqueue memory into a shared memory region
- A userspace PMD thread in OVS-DPDK polls the ring directly via `mmap`
- VM-exits are **reduced** (via `VIRTIO_F_EVENT_IDX` notification
  suppression) but not fully eliminated unless both guest and host run in
  PMD polling mode
- No kernel socket buffers; zero-copy if huge pages are configured

**Limitation:** the PMD polling thread still runs on the host CPU, burning a
full core at 100% utilization even when the ring is empty. The cost shifts
from VM-exits to dedicated CPU core burn.

<a id="43-vdpa"></a>
### 4.3 vDPA Architecture: Bypass to the DPU

**vDPA (vHost Data Path Acceleration)** is a Linux kernel framework (core
infrastructure merged in **Linux 5.7**, commit `961e9c84`; `vhost-vdpa` bus
driver in 5.7; `virtio-vdpa` module refined through **5.13+**) that
generalizes the backend of a virtio device. Instead of the host CPU (kernel
vhost-net or userspace PMD) processing the virtio rings, vDPA routes ring
traffic to a **hardware backend** — here, the ConnectX-7 ASIC's native
virtio emulation engine.

```text
┌──────────────────────────────────────────────────────────────────────┐
│                    HOST SERVER (x86_64)                              │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │              QEMU/KVM (virt-launcher)                         │   │
│  │  ┌────────────────────────────────────────────────────────┐  │   │
│  │  │              CirrOS VM (Guest)                          │  │   │
│  │  │  eth1: virtio-net driver                                │  │   │
│  │  │  TX/RX virtqueue rings (in guest physical memory)      │  │   │
│  │  └────────────────┬───────────────────────────────────────┘  │   │
│  │                   │  virtio ring (DMA-mapped)                  │   │
│  │         ┌─────────▼──────────┐                                │   │
│  │         │  vDPA bus device   │  ← /dev/vhost-vdpa-0           │   │
│  │         │  (mlx5 vDPA driver)│                                │   │
│  │         └─────────┬──────────┘                                │   │
│  └───────────────────┼───────────────────────────────────────────┘   │
│                      │  PCIe DMA (ring address mapping)               │
│                      │  NO host CPU involvement beyond this point     │
└──────────────────────┼───────────────────────────────────────────────┘
                       │  PCIe bus
┌──────────────────────▼───────────────────────────────────────────────┐
│                   BLUEFIELD-3 DPU                                     │
│                                                                      │
│         ┌────────────────────────────────────────────────────┐       │
│         │           ConnectX-7 ASIC                           │       │
│         │  ┌──────────────────────────────────────────────┐  │       │
│         │  │  virtio emulation engine (hardware)           │  │       │
│         │  │  • Polls guest virtqueue rings via PCIe DMA   │  │       │
│         │  │  • Parses virtio descriptors in silicon       │  │       │
│         │  │  • Matches against hardware flow tables       │  │       │
│         │  │  • Forwards to physical port / other VFs      │  │       │
│         │  │  • Writes completion descriptors back to ring │  │       │
│         │  └──────────────────────────────────────────────┘  │       │
│         │                          │                           │       │
│         │              Physical network ports                  │       │
│         │              (400G line rate, hardware paced)        │       │
│         └────────────────────────────────────────────────────┘       │
└──────────────────────────────────────────────────────────────────────┘
```

**The critical property:** guest virtio rings are DMA-mapped directly into
the ConnectX-7 ASIC's address space via PCIe. When the VM writes a
descriptor to the TX ring, the ASIC reads it, DMA-fetches the payload
directly from guest physical memory, applies flow table actions, and
transmits. **The host CPU is not in the datapath at all.**

The only remaining host CPU involvement:

1. Initial setup — QEMU calls `ioctl(VHOST_VDPA_SET_VRING_ADDR)` to register
   ring addresses
2. Rare exceptions — hardware punts a non-matchable packet to the DPU Arm SoC
3. Control plane — Kubernetes/KubeVirt updating flow rules via OVS-DOCA APIs

<a id="44-cloud-native"></a>
### 4.4 Cloud-Native Abstraction Preservation

A critical design goal of the vDPA/Switchdev architecture is transparency to
the Kubernetes control plane — the cluster should not need to "know" that
hardware offload is happening.

| Abstraction Layer | Software OVS | DPU-offloaded |
|-------------------|-------------|----------------|
| NetworkAttachmentDefinition | Same YAML | Same YAML |
| Multus annotation | Same pod annotation | Same pod annotation |
| OVS-CNI plugin | Creates veth pair + OVS port | Creates VF representor + OVS port |
| KubeVirt binding | `bridge` mode | `vDPA` or `SRIOV` binding mode |
| NetworkPolicy | OVS OpenFlow rules | OVS-DOCA HW flow rules (same API) |
| kubectl / virtctl | No change | No change |

The only change visible to a DevOps engineer is the VM spec's interface
binding type — everything above the CNI layer stays identical.

---

<a id="5-part-iv"></a>
## 5. Part IV — Full Offloaded Packet Walk

**Scenario:** CirrOS VM1 sends a UDP packet to VM2 on the same OVS network
(intra-node, both VMs have vDPA NICs).

```text
Step 1: VM1 Guest (eth1, virtio-net driver)
  └── Write TX descriptor to virtqueue ring buffer
  └── Write doorbell register (MMIO) → PCIe write to ConnectX-7

Step 2: ConnectX-7 ASIC (DPU internal)
  └── Detect doorbell via PCIe
  └── DMA read of virtio TX descriptor from guest physical memory
  └── DMA read of packet payload (UDP frame) from guest physical memory
  └── NO HOST CPU INVOLVEMENT FROM THIS POINT

Step 3: ConnectX-7 Hardware Flow Table Lookup
  └── Match: {src_mac=VM1_MAC, dst_mac=VM2_MAC, vlan=100}
  └── Action: Forward to VF1 (VM2's vDPA device port)
  └── Lookup time: sub-microsecond hardware-matched lookups (TCAM)

Step 4: ConnectX-7 → VM2's virtqueue (DMA write)
  └── DMA write of packet into VM2's RX ring buffer (guest physical memory)
  └── Write RX completion descriptor to VM2's virtqueue
  └── Signal VM2 via PCIe interrupt (or ring polling if IOMMU passthrough)

Step 5: VM2 Guest (eth1, virtio-net driver)
  └── Interrupt fires (or NAPI polling picks up RX descriptor)
  └── Read packet from virtqueue
  └── Deliver to VM2's guest network stack (UDP socket, etc.)

TOTAL HOST CPU CYCLES CONSUMED: ~0 (only interrupt coalescing at VM2 entry)
LATENCY: single-digit microseconds end-to-end
         (estimated vendor performance, vs. ~20–100 µs for software OVS)
```

---

<a id="6-part-v"></a>
## 6. Part V — Architectural Comparison Matrix

| Dimension | Software OVS (Lab) | OVS-DOCA + vDPA (Production DPU) |
|-----------|--------------------|------------------------------------|
| Packet throughput (64B) | 10–25 Mpps (estimated) | 500+ Mpps (vendor-published, ConnectX-7 @ 400G) |
| Forwarding latency | 20–100 µs (estimated) | 1–3 µs (vendor-published) |
| CPU overhead | 2–4 cores dedicated to OVS | ~0 (exception path only) |
| Flow table size | Kernel memory limited (~1M, estimated) | Millions of exact-match hash entries + ~256K–1M TCAM wildcard entries (vendor limits) |
| Memory bandwidth | Shared with tenant workloads | Separate DPU memory bus |
| Live migration support | Native (no special handling) | Complex (see §7.1) |
| Observability | Full OVS tooling, eBPF | DOCA Telemetry Service (DTS), limited eBPF |
| Vendor dependency | None (open source) | NVIDIA BlueField + DOCA SDK |
| Hardware cost | $0 (software-only) | Significant per-node CAPEX |
| Failure blast radius | OVS crash → all VMs on host lose network | DPU failure → entire server offline |
| Security boundary | Shared host kernel | Isolated DPU TEE (optional) |
| NetworkPolicy enforcement | OVS OpenFlow (host kernel) | DOCA HW flow rules (DPU silicon) |
| vDPA virtio ring location | N/A | Guest physical memory (DMA-mapped) |
| Tenant network isolation | OVS VLAN/VXLAN | SR-IOV VFs + hardware VLAN isolation |

---

<a id="7-part-vi"></a>
## 7. Part VI — Edge Cases & Trade-offs

This section covers genuine operational complexities that arise when
adopting DPU-based offload in production — not theoretical concerns, but
challenges encountered in large-scale deployments.

<a id="71-live-migration"></a>
### 7.1 Live Migration with Hardware Offload

**The fundamental tension:** live migration (KubeVirt `LiveMigrate`
strategy) requires a VM's virtual NIC state to be serializable and
transferable to a destination node. With software OVS, that state lives
entirely in guest memory (virtio rings) and host software (OVS flow
tables) — both easily serialized.

With vDPA, the virtio rings are DMA-mapped into the ConnectX-7 ASIC, so
state is distributed across:

1. Guest physical memory (virtio ring descriptors)
2. DPU ASIC internal state (flow context, conntrack tables)
3. DPU Arm SoC (OVS-DOCA flow program state)

**The migration problem sequence:**

```text
Phase 1 (Pre-copy): Guest memory pages are copied to the destination.
   PROBLEM: virtio ring pages are simultaneously being DMA-written by the
   source DPU — a TOCTOU race on the rings.
   Mitigation: "ring freeze" — quiesce the source DPU's DMA engine for the
   dirty ring pages.

Phase 2 (Stop-and-copy): VM is paused, remaining dirty pages copied.
   PROBLEM: the DPU ASIC has in-flight packets in its pipeline.
   Mitigation: drain the DPU pipeline before freezing (DOCA "drain" API).
   Cost: slight extra stop-and-copy downtime for hardware state.

Phase 3 (Resume at destination):
   PROBLEM: the destination DPU must re-establish the vDPA context BEFORE
   the guest resumes, or packets will be dropped.
   Mitigation: extend QEMU's migration protocol with a vDPA "restore
   context" phase via the DOCA Migration API (DOCA ≥ 2.2). Not backward
   compatible with standard QEMU migration.

Phase 4 (Post-migration OVS flow update):
   PROBLEM: the source DPU still holds the VM's MAC in its FDB and briefly
   receives duplicate packets while both source and destination OVS
   instances think the VM is local.
   Mitigation: the KubeVirt migration controller must issue OVSDB
   transactions to remove source flows AFTER the destination confirms the
   VM is running — a control-plane race requiring careful sequencing.
```

**Current state (2026):** NVIDIA DOCA 2.x includes a `doca_migration` API
handling vDPA state serialization. KubeVirt integration requires the
`doca-vdpa` migration plugin (tech-preview as of KubeVirt v1.3). For
stateful workloads, the migration window must be bounded carefully to avoid
TCP timeouts.

**Trade-off summary:** hardware-offloaded live migration is achievable but
requires the DOCA 2.x migration API, modified KubeVirt migration hooks, a
migration window roughly 2x longer than software OVS, and explicit
migration of connection-tracking state (not automatic).

---

<a id="72-failure-domain"></a>
### 7.2 Failure Domain Analysis

**Software OVS failure model:**

- `ovs-vswitchd` crash → the OVS kernel datapath keeps forwarding cached
  flows
- Flow cache expires (default 10s) → all VM traffic drops until vswitchd
  restarts
- Host kernel crash → all VMs on the host lose network (expected)
- **Blast radius:** single host

**DPU failure model — more complex:**

| Failure Type | Impact | Recovery Time |
|---|---|---|
| DPU Arm SoC crash | Cached HW flows continue; new flows fail | ~5s (vswitchd restart on DPU Arm SoC, estimate) |
| ConnectX-7 ASIC error | All traffic stops for all VMs on the host, no failover | ~30s (PCIe reset, estimate) or host reboot |
| DPU PCIe link failure | Complete host network loss, no automatic fallback | Physical intervention (DPU replacement) |
| OVS-DOCA flow programming error | New flows not installed; existing flows unaffected | ~1s (soft flow re-sync from controller, estimate) |
| DPU OS (BF-OS) crash | Full restart required; VMs experience an outage | ~120s (estimated BF-OS boot) |

**Critical insight:** the DPU is a **single point of failure** for all
network traffic on a host. In the software OVS model, OVS can be restarted
while the NIC keeps passing traffic via the kernel datapath cache. In the
DPU model, if the ConnectX-7 ASIC resets, the NIC itself is gone — there is
no fallback path.

**Mitigation strategies:**

1. **Dual-port with port bonding** — two BlueField DPUs in an
   active-standby bond. Expensive (~$6–10K/server, estimated market cost)
   but redundant.
2. **DPU watchdog + OOB management** — BlueField-3's out-of-band interface
   can monitor DPU health and trigger host fencing/evacuation before full
   failure.
3. **HA-aware VM scheduling** — pod anti-affinity to spread critical VMs
   across hosts, avoiding a single DPU failure domain.

---

<a id="73-control-plane"></a>
### 7.3 Control-Plane vs. Data-Plane Split

The DPU architecture physically separates the control plane (DPU Arm SoC)
from the data plane (ConnectX-7 silicon) — with real operational
implications.

```text
Kubernetes API Server  ──────────────────────────────────────┐
        │                                                     │
   (NetworkPolicy,                                           │
    NetworkAttachmentDef)                                    │
        │                                                     │
   ┌────▼──────────────────────────────────────────────────┐ │
   │                 DPU Control Plane                      │ │
   │  (OVS-DOCA on Arm SoC)                                 │ │
   │  • Receives OpenFlow rules from K8s controller         │ │
   │  • Compiles rules to DOCA Flow API calls                │ │
   │  • Manages OVSDB state                                  │ │
   └────┬──────────────────────────────────────────────────┘ │
        │  DOCA Flow API (hardware programming)               │
   ┌────▼──────────────────────────────────────────────────┐ │
   │                 DPU Data Plane                          │ │
   │  (ConnectX-7 ASIC)                                     │ │
   │  • Executes flow table lookups at line rate             │ │
   │  • Forwards/drops/modifies packets                      │ │
   │  • Exception packets punted back to control plane       │ │
   └────────────────────────────────────────────────────────┘ │
        │                                                     │
        └──────────────────────────────────────────────────────┘
```

**Split-brain scenario:** the Kubernetes API server (control plane) and the
ConnectX-7 ASIC (data plane) can temporarily diverge:

1. A `NetworkPolicy` is created: "deny all traffic to pod X"
2. The policy propagates to OVS-DOCA on the DPU Arm SoC
3. OVS-DOCA compiles the rule and calls `doca_flow_pipe_add_entry()` to
   program the ASIC
4. **Between steps 2 and 3:** packets continue flowing to pod X — the
   policy is not yet enforced in hardware

**Gap duration:** typically 1–50ms (order-of-magnitude estimate, depending
on DOCA batch intervals and TCAM update latency) — a security-sensitive
enforcement gap.

**Mitigation:** OVS-DOCA can run in a "fail-secure" mode with a
default-deny hardware rule installed up front, adding specific allow rules
incrementally. This inverts the gap: traffic to *new* endpoints is denied
until the rule lands, while existing connections are unaffected thanks to
hardware connection-tracking state.

**Reconciliation loops:** hardware TCAM is volatile SRAM that does not
survive a PCIe link reset or full firmware reload — but it *does* survive a
control-plane process restart. Killing `ovs-vswitchd` on the Arm SoC does
not reset the ConnectX-7 ASIC, so the ASIC keeps forwarding with its
existing flow tables. OVS-DOCA must then:

1. Read back current hardware flow state via DOCA introspection APIs
2. Diff it against the desired state in OVSDB
3. Delete stale entries and add missing ones

This reconciliation runs asynchronously in OVS-DOCA's `reconnect` library
(timing depends on flow table size and controller responsiveness). Note
that a full DPU firmware reset (`mst reset`) or a PCIe hot-unplug *will*
clear the TCAM — a distinct, more severe failure scenario.

---

<a id="74-operational-maturity"></a>
### 7.4 Operational Maturity and Trade-offs

Hardware offload brings real security and performance benefits — for
example, isolating tenant traffic from the host OS via the DPU's Trusted
Execution Environment — but it also raises the operational bar.

**Observability.** Most software OVS tooling loses visibility into
fast-path flows once they move to hardware, so teams must adopt DPU-native
telemetry (e.g., NVIDIA DOCA) and adjust runbooks accordingly.

| Observability Tool | Software OVS Datapath | Hardware-Offloaded (DPU) Datapath |
|--------------------|-----------------------|------------------------------------|
| `ovs-ofctl dump-flows` | Full visibility into all flows and hit counters | Only control-plane (exception) flows, unless hardware counters are explicitly polled (adds latency overhead) |
| `tcpdump` / packet capture | Captures all payloads on host TAP/veth interfaces | Blind to fast-path traffic — packets bypass the host CPU entirely |
| eBPF / host tracing | Traces packets via XDP/TC in the host kernel | Blind to fast-path traffic — packets never enter the host kernel stack |
| DOCA Telemetry Service | N/A | Deep hardware visibility, flow sampling, and drop counters directly from the ConnectX-7 ASIC |

**Lock-in risk.** Upstream Kubernetes distributions lack first-class DPU
provisioning support, often requiring custom device plugins and
vendor-specific APIs (DOCA). While the OVS control-plane APIs stay open,
the hardware integration itself carries meaningful lock-in risk to specific
silicon (e.g., ConnectX-7).

---

<a id="8-part-vii"></a>
## 8. Part VII — Kubernetes Integration Architecture

The full production architecture for DPU-offloaded KubeVirt networking
integrates several components that should be understood holistically:

```text
┌────────────────────────────────────────────────────────────────────────────┐
│                    KUBERNETES CONTROL PLANE                                │
│   API Server ── etcd ── Scheduler ── kubevirt-controller ── network-policy │
└───────────────────────────────┬────────────────────────────────────────────┘
                                │  (KubeVirt VMI spec, NetworkAttachmentDef)
┌───────────────────────────────▼────────────────────────────────────────────┐
│                    HOST NODE (x86_64)                                       │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │ KubeVirt virt-handler (DaemonSet)                                    │  │
│  │   - Reads VMI spec: interface binding = "vdpa"                       │  │
│  │   - Calls DOCA vDPA device plugin to claim a VF                     │  │
│  │   - Passes /dev/vhost-vdpa-N to QEMU as NIC backend                │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │ Multus CNI (DaemonSet)                                               │  │
│  │   - Reads NetworkAttachmentDefinition                                │  │
│  │   - Calls OVS-CNI plugin                                            │  │
│  │   - OVS-CNI creates veth pair; virt-handler adds TAP + Linux bridge │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │ NVIDIA VF Resource Plugin (DaemonSet)                                │  │
│  │   - Advertises BlueField-3 VFs as K8s extended resources             │  │
│  │   - resource: nvidia.com/bf3-vdpa-net                                │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  PCIe bus                                                                  │
└─────────────────────────────────────────────────────┬──────────────────────┘
                                                      │
┌─────────────────────────────────────────────────────▼──────────────────────┐
│                    BLUEFIELD-3 DPU                                          │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ BF-OS (Arm Linux)                                                     │  │
│  │   ┌─────────────────┐  ┌─────────────────┐  ┌────────────────────┐  │  │
│  │   │  OVS-DOCA       │  │  DOCA Telemetry │  │  DOCA Security     │  │  │
│  │   │  (vswitchd)     │  │  Service        │  │  (IPsec/TLS HW)    │  │  │
│  │   └────────┬────────┘  └─────────────────┘  └────────────────────┘  │  │
│  │            │ DOCA Flow API                                            │  │
│  │   ┌────────▼────────────────────────────────────────────────────┐   │  │
│  │   │  ConnectX-7 Hardware Flow Tables                              │   │  │
│  │   │  • Millions of exact-match (hash) + ~1M TCAM wildcard entries│   │  │
│  │   │    (vendor-published limits)                                  │   │  │
│  │   │  • Hardware VLAN/VXLAN/Geneve encap                          │   │  │
│  │   │  • Connection tracking (stateful)                            │   │  │
│  │   │  • Hardware metering (QoS, policing)                         │   │  │
│  │   └─────────────────────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│  2x 400G OSFP physical ports → Upstream Ethernet Fabric                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

<a id="9-conclusion"></a>
## 9. Conclusion

The shift from a software OVS datapath — as demonstrated in this lab's KinD
cluster — to a BlueField-3 DPU-offloaded datapath is a fundamental
architectural paradigm shift, not merely a performance optimization.

**What changes:**

- The host CPU is **evicted from the network fast path** entirely
- Network policy enforcement moves from **software** (vulnerable to host
  compromise) **to hardware** (isolated DPU TEE)
- Throughput scales from **~5–17 Gbps** (software OVS, 64B frames,
  estimated) **to 400 Gbps** (physical line rate)
- Latency drops from **20–100 µs** (software OVS, estimated) **to 1–3 µs**
  (vendor-published estimate for the hardware ASIC)

**What stays the same:**

- The Kubernetes API (NetworkAttachmentDefinition, Multus, KubeVirt VMI spec)
- The OVS control-plane model (OpenFlow, OVSDB)
- The operational model for cluster administrators

**What gets harder:**

- Live migration (requires DOCA migration API integration)
- Debugging and observability (hardware flow tables are opaque)
- Failure blast radius (the DPU is a single point of failure for all host
  networking)
- Vendor portability (DOCA is NVIDIA-proprietary)

The vDPA architecture, in particular, is an elegant engineering
achievement: it delivers hardware-speed networking to guest VMs while
preserving the virtio-net guest driver interface unchanged. The guest OS
never needs to know its "virtual NIC" is backed by silicon rather than a
host CPU thread — and that abstraction preservation is what makes the
architecture genuinely cloud-native. The entire infrastructure stack can
evolve from software to hardware without touching the application or guest
OS layer.

---

<a id="10-references"></a>
## 10. References

1. NVIDIA BlueField-3 DPU Architecture Guide — NVIDIA Technical
   Documentation, 2024 — https://docs.nvidia.com/networking/display/BlueFieldDPUBSP
2. DOCA Developer Guide — NVIDIA DOCA SDK, 2024 —
   https://docs.nvidia.com/doca/sdk/developer-guide
3. vDPA Linux Kernel Framework — Jason Wang, Linux 5.7+, 2020 —
   https://www.kernel.org/doc/html/latest/driver-api/vdpa.html
4. Switchdev Architecture — Jiri Pirko, Linux Kernel Documentation —
   https://www.kernel.org/doc/html/latest/networking/switchdev.html
5. Open vSwitch with DOCA Hardware Acceleration — NVIDIA Developer Blog,
   2023 — https://developer.nvidia.com/blog/accelerating-ovs-with-bluefield-dpu
6. KubeVirt Networking Deep Dive — KubeVirt Project Documentation —
   https://kubevirt.io/user-guide/virtual_machines/interfaces_and_networks/
7. Multus CNI — Multi-Network Kubernetes — CNCF Project —
   https://github.com/k8snetworkplumbingwg/multus-cni
8. OVS-CNI Plugin — k8snetworkplumbingwg —
   https://github.com/k8snetworkplumbingwg/ovs-cni
9. virtio-net: A High-Performance Para-Virtualized Network Driver — Rusty
   Russell, 2008 — https://www.ozlabs.org/~rusty/virtio-spec
10. Live Migration of Virtual Machines with vDPA — KVM Forum 2022 —
    https://kvmforum2022.sched.com (Session: "vDPA Live Migration")
11. OVN-Kubernetes with DPU Offload — Red Hat/IBM Engineering Blog, 2023 —
    https://cloud.redhat.com/blog/ovn-kubernetes-dpu-offload
12. Switchdev-based TC Hardware Offload in Linux — Saeed Mahameed,
    Mellanox, netdev 0x12 — https://www.netdevconf.info/0x12/session.html?tc-offload-switchdev