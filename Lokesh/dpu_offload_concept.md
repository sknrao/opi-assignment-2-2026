# DPU Offload Concept: From Software OVS to BlueField-3 Hardware Acceleration

**Assignment:** Cloud-Native OVS Datapath Challenge — Task 5
**Scope note (read this first):** Part 1 describes the software datapath exactly as built by `cluster_setup.sh` / `manifests.yaml` in this submission — it's a description of a real, runnable stack, not a simulation. Parts 2–5 describe BlueField-3 / DOCA / vDPA hardware offload conceptually, based on NVIDIA and upstream kernel documentation; no DPU hardware was available to test any of it. Where a number appears (throughput, latency, TCAM size), it is marked as either vendor-published or an order-of-magnitude estimate — nothing here is presented as a measurement I personally took.

---

## Table of contents
1. [The software baseline: what this lab actually runs](#1-baseline)
2. [What a DPU is and why it's a distinct architecture](#2-what-is-a-dpu)
3. [Switchdev mode and representors](#3-switchdev)
4. [OVS-DOCA: same control plane, hardware datapath](#4-ovs-doca)
5. [vDPA: bypassing the host CPU for the VM's virtio rings](#5-vdpa)
6. [Full offloaded packet walk](#6-packet-walk)
7. [Side-by-side comparison](#7-comparison)
8. [Edge cases that don't disappear with hardware offload](#8-edge-cases)
9. [What a Kubernetes engineer would actually change](#9-k8s-integration)
10. [References](#10-references)

---

<a id="1-baseline"></a>
## 1. The software baseline: what this lab actually runs

### 1.1 Topology

```
+------------------------------------------------------------------------+
| KinD WORKER NODE (container, x86_64)                                   |
|                                                                        |
|  +--------------------------------------------------------------+    |
|  | virt-launcher pod (owns the QEMU/KVM process for the VM)      |    |
|  |                                                                |    |
|  |  +----------------------------------------------------------+ |    |
|  |  | CirrOS guest                                              | |    |
|  |  |   eth0 (virtio-net) - pod/masquerade network               | |    |
|  |  |   eth1 (virtio-net) - OVS secondary network, 192.168.100.10| |    |
|  |  +---------------+--------------------------+----------------+ |    |
|  |            virtio ring (eth0)         virtio ring (eth1)        |    |
|  |                  |                          |                    |    |
|  |            vhost-net thread           vhost-net thread            |    |
|  |                  |                          |                    |    |
|  |               tap0 (fd)                  tap1 (fd)                |    |
|  +------------------+--------------------------+--------------------+    |
|                     |                          |                      |
|              Flannel veth pair         ovs-cni veth pair               |
|                     |                          |                      |
|                     v                          v                      |
|          (cluster pod network)         OVS bridge: br-ovs              |
|                                         VLAN tag: 100                  |
|                                         +----------------------------+ |
|                                         | openvswitch.ko (kernel     | |
|                                         | datapath, datapath_type    | |
|                                         | =system)                   | |
|                                         |  table 0: NORMAL action    | |
|                                         +--------------+-------------+ |
|                                                        |               |
|                                          LOCAL port: 192.168.100.1/24 |
|                                          (host side of the bridge)     |
+--------------------------------------------------------------------------+
```

This is precisely what `verification_flows.json` captures via `ovs-ofctl dump-flows br-ovs`, and what `ping_results.txt` exercises in both directions.

### 1.2 Packet walk — VM egress on eth1 (software path)

| # | Location | What happens | Runs on |
|---|----------|---------------|---------|
| 1 | Guest (`eth1`) | virtio-net driver writes a TX descriptor + payload pointer into the ring, then kicks the doorbell (MMIO write) | Guest vCPU |
| 2 | KVM | Doorbell write causes a VM-exit trap | Host CPU |
| 3 | `vhost-net` kernel thread | Reads the virtqueue descriptor, copies the packet out of guest memory into an `skb` | Host CPU (kernel thread) |
| 4 | TAP device | `skb` enters the host's normal network stack as if it arrived on a physical NIC | Host CPU (softirq) |
| 5 | `openvswitch.ko` netdev hook | Datapath (DPIF) flow-key lookup against the kernel megaflow cache | Host CPU (softirq) |
| 6 | Cache miss -> upcall | Netlink message to `ovs-vswitchd` in userspace; it evaluates the full OpenFlow table set and installs a new kernel cache entry | Host CPU (context switch + userspace) |
| 7 | Action execution | `NORMAL` action: L2 learning-switch behavior, VLAN tag applied per the bridge port's `tag=100` | Host CPU |
| 8 | Egress | Frame handed to whatever `br-ovs`'s uplink is (in this lab, nothing — it's an isolated bridge; in a real deployment, a physical NIC) | Host CPU + NIC DMA |

**The one-line summary that matters for everything that follows:** every single hop above consumes host CPU cycles, and step 6 (the upcall) is the expensive one — it's a context switch plus a full OpenFlow table walk, and it recurs for every flow that isn't already cached.

### 1.3 Known limits of this exact setup, as built

- `datapath_type=system` (kernel datapath) was used rather than `datapath_type=netdev` (OVS-DPDK) — this lab prioritizes correctness and simplicity over throughput, which is the right trade-off for a verification exercise, but it means none of DPDK's poll-mode-driver optimizations apply here. That distinction matters for Part 7's comparison table.
- OVS 3.1.x, as installed via `apt-get install openvswitch-switch` on the Debian-Bookworm-based KinD node image, does not support `ovs-ofctl dump-flows --format=json` natively — hence `parse_flows.py` in this submission, which normalizes the plain-text dump into the same nested schema modern OVS would emit natively.

---

<a id="2-what-is-a-dpu"></a>
## 2. What a DPU is and why it's a distinct architecture

A DPU is a third category of programmable processor alongside the CPU and GPU: rather than optimizing for serial branch-heavy logic (CPU) or SIMD floating point throughput (GPU), it's built around packet classification, header rewriting, and encapsulation at line rate, with a general-purpose Arm complex attached for the parts of the job that aren't reducible to fixed-function silicon.

Physically, the NVIDIA BlueField-3 is a PCIe card. To the host, it enumerates as a NIC. Internally it contains:

- An **Arm Cortex-A78AE cluster** running its own independent Linux distribution (BlueField's "DPU OS"), with its own kernel, its own `ovs-vswitchd`, its own process table — entirely separate from the host's.
- The **ConnectX-7 network ASIC**, which holds hardware flow-matching tables (a combination of exact-match hash tables and TCAM for wildcard/range matches) and does the actual packet steering.
- Dedicated crypto/compression/regex accelerator blocks (relevant to IPsec/TLS offload, not this datapath discussion).
- A PCIe interface back to the host, through which the host sees representor netdevs and/or SR-IOV VFs, not the DPU's internal Arm OS.

The important conceptual shift versus a plain SmartNIC: the BlueField-3 doesn't just accelerate a fixed function, it **relocates an entire independent OS and control-plane process (`ovs-vswitchd`)** off the host's CPU and onto the card, while giving that control plane direct programming access to a hardware-forwarding ASIC.

```
+-----------------------------------------------------------------+
| BLUEFIELD-3 (PCIe card)                                          |
|                                                                   |
|  +---------------------------+    +--------------------------+  |
|  | Arm Cortex-A78AE (DPU OS) |    | ConnectX-7 ASIC           |  |
|  |  ovs-vswitchd (OVS-DOCA)  |--->|  hardware flow tables     |  |
|  |  DOCA Flow / Telemetry    |    |  (hash + TCAM)             |  |
|  +---------------------------+    |  packet processor          |  |
|                                    |  (VLAN, VXLAN, rewrite)    |  |
|                                    |  physical ports (400G)     |  |
|                                    +----------------------------+  |
+------------------------+------------------------------------------+
                         | PCIe
+------------------------v------------------------------------------+
| HOST SERVER                                                        |
|  Sees: representor netdevs (switchdev mode) and/or SR-IOV VFs      |
|  Does NOT run: ovs-vswitchd, openvswitch.ko for this traffic       |
+---------------------------------------------------------------------+
```

---

<a id="3-switchdev"></a>
## 3. Switchdev mode and representors

Switchdev is the Linux kernel mechanism (mainlined years ago, mature well before BlueField-3) that lets a NIC's hardware switching ASIC be exposed to userspace tooling through ordinary-looking Linux netdevs. Concretely, once a BlueField-3 physical function is put into switchdev mode, the PF takes on the role of the embedded switch's uplink, and the standard netdev/RDMA interfaces become the way software interacts with that switch — rather than the PF behaving like a conventional standalone NIC port.

Each SR-IOV VF that used to appear on the host as a raw, independent NIC (in legacy SR-IOV passthrough mode) instead gets a matching **representor netdevice**. A representor:

- Does **not** carry the VF's actual data-plane traffic — it's a control handle, not a wire.
- Can be attached to `br-ovs` (or its OVS-DOCA equivalent on the Arm side) exactly like the `veth` end this lab attaches via `ovs-cni`.
- Receives only the traffic the ASIC couldn't classify — "miss" traffic that gets punted up to software for a slow-path decision.

```
Host kernel view under switchdev mode:
  ens1f0        <- representor for PF0
  ens1f0vf0     <- representor for VF0 (assigned to VM1's NIC)
  ens1f0vf1     <- representor for VF1 (assigned to VM2's NIC)

None of these carry bulk traffic. Flow rules attached to them (via `tc flower`,
or via OVS-DOCA's DOCA Flow calls on the Arm side) get compiled by the driver
into hardware TCAM/hash entries on the ConnectX-7 ASIC.
```

This is the layer that lets `ovs-cni`'s existing `bridge`-attachment model generalize to hardware offload without a new CNI plugin: ovs-cni already supports passing a `deviceID` (a VF's PCI address) instead of creating a plain veth, specifically for this representor-based hardware-offload case.

---

<a id="4-ovs-doca"></a>
## 4. OVS-DOCA: same control plane, hardware datapath

NVIDIA ships OVS in three flavors for BlueField: OVS-Kernel, OVS-DPDK, and **OVS-DOCA**. OVS-DOCA keeps the OpenFlow API, CLI tools (`ovs-ofctl`, `ovs-vsctl`, `ovs-appctl`), and OVSDB schema identical to the other two — the change is entirely in the DPIF (datapath interface) backend, which is rebuilt on top of NVIDIA's DOCA Flow library instead of the Linux kernel datapath or DPDK's software poll-mode drivers.

**What OVS-DOCA's DPIF does differently:**

1. `ovs-vswitchd`, running on the DPU's Arm cores (not the host), compiles OpenFlow rules into a form the ConnectX-7 ASIC can execute directly.
2. Those compiled rules are pushed to hardware via the DOCA Flow API.
3. Matched packets are steered entirely by the ASIC — zero Arm CPU involvement, and critically, zero host x86 CPU involvement, for the fast path.
4. Only **exception packets** — first packet of a new flow, ARP, control-plane traffic the hardware can't classify — get punted to the Arm cores for a software decision, exactly analogous to a kernel-datapath upcall in Part 1, except it happens on the DPU's Arm complex instead of the host's x86 cores.

| | Software OVS (this lab) | OVS-DOCA |
|---|---|---|
| Where `ovs-vswitchd` runs | Host x86 | DPU Arm SoC |
| Where the fast path executes | Host x86 (kernel datapath cache) | ConnectX-7 ASIC (hardware TCAM/hash) |
| Slow-path (miss) cost | Host x86 context switch + Netlink upcall | DPU Arm context switch — host CPU untouched |
| `ovs-ofctl dump-flows` semantics | Standard | Identical CLI surface; flow entries additionally expose hardware offload status |

The consequence for `verification_flows.json` specifically: the same `ovs-ofctl dump-flows br-ovs` command you'd run against this lab's software bridge is *also* the verification command on a DOCA-offloaded bridge — the artifact format doesn't change, only where the underlying forwarding actually happens.

---

<a id="5-vdpa"></a>
## 5. vDPA: bypassing the host CPU for the VM's virtio rings

Switchdev/OVS-DOCA (Sections 3–4) offload the *switching* decision. vDPA is a separate, complementary piece that changes how the **VM's own virtio-net device** is backed — independent of whether the switch itself is offloaded.

### 5.1 Why vDPA exists

The guest's virtio-net driver is unmodified in all of the following models — that's virtio's whole point, a stable paravirtualized ABI the guest never has to know the details behind. What varies is who services the other end of the ring:

| Backend | Where ring processing happens | Host CPU cost per packet |
|---|---|---|
| `vhost-net` (this lab, Part 1) | Host kernel thread | Copy + VM-exit per notification |
| `vhost-user` (OVS-DPDK) | Host userspace PMD thread, polling shared memory | Zero-copy possible, but a full CPU core spins at 100% polling the ring even when idle |
| **vDPA** | Hardware backend (ConnectX-7's virtio emulation engine) reached via the kernel's `vhost-vdpa` bus driver | Effectively zero — no host-resident thread services the ring at all |

The vDPA kernel framework (core merged into mainline Linux in March 2020, kernel 5.7) exists specifically to hide the vendor-specific complexity of different hardware vDPA implementations and present one unified interface to both kernel and userspace consumers, regardless of whether the underlying device is a PF, VF, or another vendor-specific slice such as a subfunction. Two bus drivers matter here: `vhost-vdpa`, which exposes a vhost character device so a VMM like QEMU can drive the hardware datapath directly on behalf of a guest virtio driver — the model relevant to our KubeVirt VM — and `virtio-vdpa`, which instead presents the vDPA device as an ordinary kernel virtio device for bare-metal/container consumption, not directly relevant here.

### 5.2 Mechanically, what changes

```
+---------------------------------------------------------------------+
| HOST SERVER                                                          |
|  +-----------------------------------------------------------+      |
|  | QEMU (virt-launcher)                                        |     |
|  |  +--------------------------------------------------------+ |     |
|  |  | CirrOS guest - eth1: virtio-net (UNCHANGED driver)      | |     |
|  |  |   TX/RX virtqueue rings, in guest physical memory       | |     |
|  |  +---------------------+------------------------------------+     |
|  |            virtio ring address registered via                     |
|  |            ioctl(VHOST_VDPA_SET_VRING_ADDR)                        |
|  |                       |                                            |
|  |            +----------v---------+                                 |
|  |            | /dev/vhost-vdpa-N  | <- kernel vhost-vdpa bus         |
|  |            +----------+---------+                                 |
|  +-----------------------+---------------------------------------+   |
|                          | DMA-mapped ring addresses (PCIe)            |
|               NO host CPU thread services this ring beyond setup      |
+---------------------------+-------------------------------------------+
                            | PCIe
+---------------------------v-------------------------------------------+
| BLUEFIELD-3                                                            |
|  ConnectX-7 virtio emulation engine:                                   |
|   - Polls the guest's virtqueue directly via PCIe DMA                  |
|   - Parses virtio descriptors and fetches payload from guest memory    |
|   - Runs the packet through the same hardware flow tables as Sec.4    |
|   - Writes completions back into the guest's RX ring via DMA          |
+--------------------------------------------------------------------------+
```

The guest is unaware any of this changed — it's still just a virtio-net device from its point of view. That guest-transparency is deliberate and is what makes vDPA viable for a KubeVirt/OpenStack-style cloud that can't assume custom guest images.

### 5.3 What still touches the host CPU

1. **Setup only** — QEMU issues vDPA control ioctls once, at VM start, to register ring addresses and negotiate features.
2. **True exceptions** — anything the hardware genuinely cannot classify gets punted to the DPU's Arm cores (not the host).
3. **Kubernetes/KubeVirt control plane** — reconciling `VirtualMachine`/`NetworkAttachmentDefinition` state, which was always a control-plane concern and stays one.

---

<a id="6-packet-walk"></a>
## 6. Full offloaded packet walk

**Scenario:** VM1 and VM2, both vDPA-backed, both on the same OVS-DOCA bridge, same node.

| # | Location | Operation | Host x86 CPU involved? |
|---|----------|-----------|--------------------------|
| 1 | VM1 guest | virtio-net writes TX descriptor + kicks doorbell (PCIe MMIO, trapped by the ConnectX-7, not by KVM) | No |
| 2 | ConnectX-7 | Detects doorbell, DMA-reads the descriptor and payload directly from VM1's guest physical memory | No |
| 3 | ConnectX-7 hardware flow table | Matches `{src_mac=VM1, dst_mac=VM2, vlan=100}` against the compiled OVS-DOCA ruleset | No |
| 4 | ConnectX-7 | DMA-writes the payload into VM2's RX ring, writes the completion descriptor, signals VM2 | No |
| 5 | VM2 guest | Guest interrupt (or NAPI poll) picks up the RX descriptor, delivers to its network stack | No (guest vCPU only) |

Compare against Part 1's table: every hop there was annotated "Host CPU." Here, none are, apart from one-time setup. The only place a genuinely new packet flow touches a CPU at all is the *first* packet, which gets punted to the DPU's own Arm cores — not the host's — to let `ovs-vswitchd` (on the DPU) compile and install the new hardware rule.

---

<a id="7-comparison"></a>
## 7. Side-by-side comparison

| Dimension | This lab (software OVS, kernel datapath) | BlueField-3 (OVS-DOCA + vDPA) |
|---|---|---|
| Guest driver | virtio-net | virtio-net (byte-for-byte identical) |
| Ring backend | `vhost-net` (host kernel thread) | ConnectX-7 virtio emulation engine (hardware) |
| CNI-visible port type | veth (via `ovs-cni`, plain `bridge` config) | VF representor (via `ovs-cni`'s `deviceID` field) |
| eSwitch mode | N/A (plain OVS bridge, no eSwitch concept) | switchdev mode |
| `ovs-vswitchd` location | Host x86 | DPU Arm SoC |
| Fast-path execution | Host x86 (kernel megaflow cache) | ConnectX-7 ASIC hardware tables |
| Flow-table verification command | `ovs-ofctl dump-flows br-ovs` (this submission) | Identical command; add `-m` or `type=offloaded` filters to see hardware-resident flows specifically |
| Per-packet host CPU cost, steady state | Non-zero (documented in Section 1.2) | ~zero |
| First-packet cost | Same as steady state (no separate fast/slow path exists) | One-time hardware-rule install (DPU Arm, not host) |
| Throughput ceiling | Kernel-datapath OVS on general-purpose x86 typically tops out well below 100 Gbps; exact figure is workload- and CPU-dependent, not something this lab measured | Vendor-published line-rate figures for ConnectX-7 (up to 400 Gbps per port) — not independently verified here |
| Live migration | Native, no special handling (state lives in guest memory + host OVS only) | Requires DOCA's migration-aware vDPA path (see Section 8.1) |

---

<a id="8-edge-cases"></a>
## 8. Edge cases that don't disappear with hardware offload

These aren't hypothetical concerns invented for completeness — they're the standard list of things a platform team has to answer before shipping DPU offload in production, and each one has a real trade-off, not just a "hardware makes it faster" upside.

### 8.1 Live migration

With vDPA, ring state is genuinely split across three places instead of one: guest memory (ring descriptors), the ConnectX-7 ASIC (in-flight packets, connection-tracking state), and the DPU's own OVS-DOCA process state. A correct migration has to:

1. Quiesce the source DPU's DMA engine against the ring pages before the final memory pre-copy round, to avoid a source-side write racing the migration's page copy.
2. Drain in-flight packets from the ASIC pipeline before pausing the guest (a stop-and-copy step that has no equivalent in the software-OVS case, where "in-flight" just means "in a kernel skb queue" and is trivially preserved).
3. Re-establish the vDPA device context at the destination *before* the guest resumes, or early packets get silently dropped.
4. Reconcile OVS-DOCA flow state on both source and destination so the VM's MAC isn't briefly forwardable to two places at once.

None of this is exotic — it's the standard problem of migrating any stateful hardware-offloaded connection — but it is real additional engineering surface area that a software-only OVS deployment simply doesn't have to solve, and one reason DPU rollout plans typically budget extra validation time specifically for the live-migration path. It's worth noting this is an area of active kernel/QEMU development rather than a fully solved problem — vDPA's design goal is to make live migration between different vendor NICs and driver versions possible precisely because the ring layout is now the standard virtio layout rather than something vendor-specific, but the DPU-side state serialization described above is the part that's still maturing.

### 8.2 Failure domain

In the software model, `ovs-vswitchd` can crash and restart while the kernel datapath's *cached* flows keep forwarding traffic for up to the cache's idle timeout — a soft failure. In the DPU model, if the ConnectX-7 ASIC itself faults (not just the Arm-side control process), **the host's network is gone**, full stop — there's no fallback to a kernel datapath, because the kernel datapath for that traffic never existed on the host in the first place. This is the central trade-off of DPU offload: you gain enormous headroom and CPU-cycle savings, but you also concentrate a hard, unrelated failure mode (a NIC-adjacent ASIC or its PCIe link) into something that now determines whether the *whole host* has network connectivity, not just one interface.

Production deployments mitigate this with dual-DPU active/standby bonding, or aggressive DPU health-check-driven workload eviction — neither of which has an analogue in this lab's single-bridge setup.

### 8.3 Control-plane / data-plane consistency gap

Because policy compilation (Arm SoC) and policy enforcement (ConnectX-7 ASIC) are physically separate, there's a window — small, but nonzero — between "a `NetworkPolicy` was accepted by the Kubernetes API server" and "the corresponding hardware rule is actually installed in the ASIC." Traffic that should now be denied can still be forwarded for that window unless the platform runs with a default-deny hardware rule pre-installed and only adds allow-rules incrementally (a "fail-secure" posture). This is a genuine security-relevant detail, not a performance footnote, and it's the kind of thing that would need to be explicitly validated (not assumed) before trusting DPU-offloaded NetworkPolicy enforcement in a multi-tenant cluster.

### 8.4 Observability shifts, it doesn't just improve

`tcpdump` and eBPF/XDP tracing on the host are blind to fast-path traffic in the DPU model, because that traffic genuinely never enters the host kernel's network stack — it's not that visibility got worse, the traffic's physical path changed. Operationally this means the same debugging muscle memory ("just tcpdump the veth") stops working, and teams need DPU-native telemetry (NVIDIA's DOCA Telemetry Service, or hardware counters polled explicitly) as a first-class part of the runbook, not an optional extra.

---

<a id="9-k8s-integration"></a>
## 9. What a Kubernetes engineer would actually change

Given this lab's `manifests.yaml` and `cluster_setup.sh`, here's specifically what would and wouldn't need to change to target BlueField-3:

**Unchanged:**
- The `NetworkAttachmentDefinition` schema and the Multus pod annotation mechanism.
- The `VirtualMachine` spec's guest-facing configuration — `interfaces`/`networks` stay the same shape, because vDPA's entire purpose is guest transparency.
- `ovs-ofctl dump-flows <bridge>` as the verification command.

**Changed:**
- The NAD's `config` JSON: instead of `"bridge": "br-ovs"` with no `deviceID`, a hardware-offload NAD supplies a VF's PCI `deviceID`, letting `ovs-cni` attach a representor instead of creating a plain veth.
- The KubeVirt interface binding: `bridge: {}` becomes a `vdpa`-aware binding (or SR-IOV passthrough, if hardware offload without vDPA's virtio-transparency is acceptable).
- One-time host/cluster setup: putting the BlueField-3 PF into switchdev mode (`devlink dev eswitch set pci/<PF> mode switchdev`), provisioning VFs, and installing OVS-DOCA (not stock kernel OVS) on the DPU's Arm side rather than the host.
- The device-plugin layer: a DOCA-aware Kubernetes device plugin advertises VFs as schedulable extended resources, analogous to how the existing `ovs-cni-marker` daemonset in this lab advertises OVS-bridge availability per node.

---

<a id="10-references"></a>
## 10. References

- NVIDIA DOCA documentation — switching support, OVS-DOCA hardware acceleration, and BlueField-3 architecture overview (docs.nvidia.com/doca)
- Red Hat vDPA kernel framework series (parts 1–3) and "Achieving network wirespeed... introducing vDPA" — background on `vhost-vdpa`/`virtio-vdpa` bus drivers and the vDPA kernel subsystem merged in Linux 5.7
- `k8snetworkplumbingwg/ovs-cni` — hardware-offload (`deviceID`) configuration option, in the same repository referenced by this lab's `cluster_setup.sh`
- KubeVirt user guide — network interface binding types (`bridge`, `masquerade`, SR-IOV)
- Linux kernel documentation — switchdev subsystem overview
