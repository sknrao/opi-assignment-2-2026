# From Software OVS to DPU-Accelerated vDPA: Architectural Shift

This document explains how the software datapath built in this lab would change
when ported to an NVIDIA BlueField-3 DPU using SR-IOV in switchdev mode, vDPA,
and OVS-DOCA. It is a conceptual write-up; the lab is intentionally software-
only (no DPU hardware in this VM).

References cited inline:
- NVIDIA BlueField-3 DPU: <https://www.nvidia.com/en-us/networking/products/data-processing-units/>
- NVIDIA DOCA OVS-DOCA: <https://docs.nvidia.com/doca/archive/doca+2.5.0/ovs-doca/index.html>
- mlx5 Linux driver — switchdev & eswitch representors: <https://github.com/Mellanox/mlx5/wiki/Setting-up-Switchdev-eSwitch>
- Linux kernel vDPA subsystem: `Documentation/networking/vdpa.rst` in the Linux
  source tree (<https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/Documentation/networking/vdpa.rst>)
- KubeVirt network binding plugins (v1.8.4): <https://github.com/kubevirt/kubevirt/blob/v1.8.4/docs/network/network-binding-plugin.md>

---

## 1. Software datapath recap (what we built)

The end-to-end path of a packet from inside the CirrOS VM to outside the
k3s host:

```
┌─────────────────────────────────────────────────────────────────────┐
│ k3s host (this Debian VM, single-node k3s server+agent)            │
│                                                                     │
│   CirrOS guest                                                     │
│     eth0 (virtio-net)                                              │
│       │                                                             │
│       │ tap (managedTap binding, virt-launcher pod)                │
│       │                                                             │
│       ▼                                                             │
│   virt-launcher pod (KubeVirt)                                     │
│     veth leg 1: inside the pod network namespace                   │
│     veth leg 2: attached to br-ovs by ovs-cni                       │
│       │                                                             │
│       ▼                                                             │
│   br-ovs  (kernel OVS datapath on the host)                        │
│     192.168.200.1/30  (host side of the /30)                       │
│                                                                     │
│   [no physical NIC; br-ovs is a software-only bridge on the host]  │
└─────────────────────────────────────────────────────────────────────┘
```

Every packet the VM sends walks through the **CPU on the host**:
the kernel OVS datapath matches flows, executes actions (output to port,
mod-NWSRC, etc.), and re-injects via a veth pair. The host CPU is in the
critical path on every packet.

The ovs-cni plugin's role is small but crucial: when a virt-launcher pod
asks for the `ovs-net` secondary network, the CNI plugin (running at
`/opt/cni/bin/ovs` inside the daemon-set pod, with `/var/run/openvswitch`
mounted from the host) creates the veth pair and `ovs-vsctl add-port`
attaches the host-side leg to `br-ovs`. KubeVirt's `managedTap` binding
exposes that veth to the guest as a tap device — this is the "Domain
Attachment" piece.

What we proved:
1. L3 connectivity over an OVS bridge.
2. OVS sees the VM's traffic (flow dumps show ICMP and ARP).
3. Multus + OVS-CNI + KubeVirt cooperate end-to-end.

What we did **not** prove (because the lab is software-only):
- Throughput at line rate (limited by kernel OVS in userspace-kernel context switch).
- Isolation from host CPU scheduling jitter.
- Hardware offload of any kind.

---

## 2. DPU hardware path (where the bridge stops being software)

The NVIDIA BlueField-3 is a SmartNIC that combines:

- An **ARM SoC** (8 × Cortex-A78 cores) running Linux on the DPU itself
  (the "DPU OS").
- A **ConnectX-7 / "BlueField-3 NIC"** exposing PCIe and physical Ethernet.
- An internal **eSwitch** (an ASIC-level packet-processing block) controlled
  by the `mlx5_core` driver via the hardware steering interface.

In a real deployment, one or more BlueField-3 cards are plugged into the
"host" server. The host runs the KubeVirt control plane; the DPU owns the
data plane. The physical NIC is in **SR-IOV switchdev mode**:

```
                  ┌───────────────────────────────────────┐
                  │              Host (x86)                │
                  │  kubelet, KubeVirt operator, virt-h…  │
                  │   ─── no kernel OVS, no br-ovs ───   │
                  │                                       │
                  │   virt-launcher pod                   │
                  │     vfio-pci  →  PCI VF on the DPU     │
                  └────────────────┬──────────────────────┘
                                   │ PCIe
                  ┌────────────────┴──────────────────────┐
                  │         BlueField-3 (DPU)              │
                  │                                       │
                  │   ARM cores (DPU OS)                  │
                  │     ovs-doca daemon                   │
                  │     ↕ /opt/mellanox/doca/services     │
                  │                                       │
                  │   eSwitch (hardware)                  │
                  │     ↕ TC/flower + representors        │
                  │                                       │
                  │   mlx5_core (DPU-side driver)         │
                  │   ConnectX-7 NIC  ──→  physical port  │
                  └────────────────┬──────────────────────┘
                                   │ Ethernet
                              external network
```

Three structural differences vs. the software lab:

1. **The bridge moves from the host to the DPU.** In our lab `br-ovs`
   lives on the k3s host. In the DPU world, OVS-DOCA on the DPU OS
   controls the eSwitch via representors — the host no longer runs OVS
   at all for the data path.
2. **The host CPU stops touching packets.** In our lab every ICMP echo
   consumes host cycles for OVS flow matching and veth re-injection.
   With the DPU, the eSwitch does the matching in hardware and only
   unmatched packets (e.g. first-packet-of-a-flow for connection tracking)
   are punted to the DPU ARM cores.
3. **SR-IOV VFs replace the veth pair.** Each VM-attached port becomes a
   PCIe VF (`enp3s0f0v0`, `enp3s0f0v1`, …) rather than a veth leg on a
   software bridge.

---

## 3. vDPA as the bus between VM and DPU

vDPA is the kernel abstraction that lets a VM's virtio datapath run
against a "real" device behind a vfio-pci front. For a vDPA NIC:

```
guest virtio driver
   └─ virtio-pci (in guest)
        └─ vhost_vdpa (kernel module, in host kernel or DPU OS)
             └─ vdpa_sim OR vdpa-mlx5 (backend)
                  └─ physical or virtual netdev
```

Three concrete benefits for the lab-to-DPU transition:

1. **Live migration stays possible.** vDPA preserves the virtio contract
   the guest sees, so the guest's virtio-net driver does not change. The
   binding between the guest and the underlying hardware shifts, but the
   guest is unaware.
2. **Kernel-bypass without guest-bypass.** DPDK-style performance without
   pulling DPDK into the guest.
3. **Hardware offload stays an accelerator.** The matching/forwarding can
   be done by the eSwitch (no software path) while the VM still sees a
   normal virtio-net device.

Caveat: in KubeVirt v1.8.4, **a built-in vDPA binding plugin is not
shipped**. The supported binding plugins in v1.8.4 are
`passt` / `macvtap` / `slirp` plus the "Zero Code Plugin" using
`DomainAttachmentType: tap` or `managedTap`
([KubeVirt v1.8.4 docs](https://github.com/kubevirt/kubevirt/blob/v1.8.4/docs/network/network-binding-plugin.md)).
The netlink library shipped with KubeVirt includes vDPA helpers, but the
production-grade vDPA integration relies on a **custom binding plugin or a
partner project** (e.g. SR-IOV device plugin + a network binding plugin
that uses `vfio-pci` directly). The path is on the v1.9.x roadmap.

So in v1.8.4 production deployments, the typical DPU story is:

- VM uses **`managedTap`** or **`passt`** binding for the guest-side vNIC.
- The CNI used for secondary networks is **SR-IOV** (not `ovs`), creating
  a PCIe VF.
- A **device plugin + network binding plugin combo** stitches the VF
  into the guest.
- vDPA shows up as an *optional* accelerator on top of that, applied via
  a vendor-specific binding plugin, not as the core mechanism.

---

## 4. Switchdev representors (how OVS-DOCA talks to the eSwitch)

When `mlx5_core` runs in switchdev mode (the canonical setup for DPU
offload), each PCIe VF and each PF is exposed in the kernel as two
**representor netdevs**:

- **Host representor** (`enp3s0f0`) — the host-side view of the physical
  function.
- **VF representors** (`enp3s0f0v0`, `enp3s0f0v1`, …) — one per VF, each
  representing a single VM's network namespace port from the eSwitch's
  point of view.

OVS-DOCA on the DPU OS treats the representors as bridge ports. A packet
from VM #1 arrives at `enp3s0f0v0` (the kernel hands it to OVS via the
representor); OVS-DOCA matches its flow table; the action is typically
`output:enp3s0f0` (send out the physical NIC) or
`output:enp3s0f0v3` (hairpin to a peer VM). The action is then compiled
into hardware steering rules (via TC + `mlx5`'s HW offload interface) so
that **subsequent packets in the same flow never leave the eSwitch**.

Two consequences for our lab:

1. **`br-ovs` becomes a switchdev bridge on the DPU**, with
   representors as ports instead of veths. The bridge config is identical
   in shape (same OpenFlow semantics, same OVS CLI); only the port types
   differ.
2. **The "see traffic with `ovs-ofctl`" verification in our lab becomes
   a `ovs-vsctl show` + `ovs-dpctl show` dump on the DPU** — same tool,
   different host. Because OVS-DOCA exposes hardware-offloaded datapaths,
   `dump-flows` on a `system@ovs-doca` datapath shows flows whose
   `actions` field references `set_mask`/`push_vlan` HW offload actions,
   not the `set`/`output` actions our lab would emit.

---

## 5. What changes in our lab manifests

The shape of `manifests.yaml` for a BlueField-3 / vDPA deployment:

```diff
--- manifests.yaml (software lab, OVS-CNI + Multus)
+++ manifests.yaml (BlueField-3 + vDPA)
```

### Namespace
```diff
   namespace: vm-lab
```
(unchanged)

### NetworkAttachmentDefinition

```diff
-apiVersion: k8s.cni.cncf.io/v1
-kind: NetworkAttachmentDefinition
-metadata:
-  name: ovs-net
-  namespace: vm-lab
-spec:
-  config: |
-    {
-      "cniVersion": "0.4.0",
-      "type": "ovs",
-      "bridge": "br-ovs",
-      "vlan": 0
-    }
+apiVersion: k8s.cni.cncf.io/v1
+kind: NetworkAttachmentDefinition
+metadata:
+  name: sriov-net
+  namespace: vm-lab
+spec:
+  config: |
+    {
+      "cniVersion": "0.4.0",
+      "type": "sriov",
+      "vlan": 0,
+      "vhostVDPAPlugin": {
+        "noResourceAnnotation": true,
+        "vhostVdpaContainerPath": "/tmp/dpdkvhostusercontainers/<pci>",
+        "vhostVdpaDevicePath": "/dev/vdpa/<vdpa-device-name>"
+      }
+    }
```

Three substantive changes:
- `type` flips from `ovs` to `sriov`.
- A `vhostVDPAPlugin` block is added so the SR-IOV CNI hands a vDPA device
  (via `/dev/vdpa/<name>`) to virt-handler, not a plain netdev.
- The implicit `bridge: br-ovs` reference is removed; the bridge lives on
  the DPU, not in the manifest.

### VirtualMachine

```diff
 spec:
   template:
     spec:
       domain:
         devices:
           interfaces:
             - name: ovs-net
-              binding:
-                name: managedTap
+              binding:
+                # In KubeVirt 1.8.4 there is no built-in vdpa binding plugin;
+                # we use the zero-code plugin with a tap domain attachment.
+                # A vendor binding plugin (or a future v1.9+ built-in) would
+                # expose this as a vhost_vdpa backend.
+                name: managedTap
+                domainAttachmentType: tap
               macAddress: "52:54:00:6c:6f:01"
       networks:
         - name: ovs-net
           multus:
-            networkName: ovs-net
+            networkName: sriov-net
```

### Cloud-init
```diff
 # No real change to the network-config; the IP scheme stays.
 # What changes is the implementation under the IP: the packet that
 # leaves the VM hits a vfio-pci / vhost_vdpa endpoint on the DPU
 # instead of a veth on a software bridge.
```

### New cluster-side resources (not in our lab)

In a real BlueField-3 deployment, the cluster also needs:
- An **SR-IOV device plugin** (`sriov-device-plugin` DaemonSet) advertising
  the DPU's VFs to the kubelet, with the right `resourceName` annotation
  referenced by the NAD's `vhostVDPAPlugin`.
- A **DPU-side `ovs-doca` daemon** (replaces the kernel OVS on the host).
- A **representor-netdev helper** that maps each VF's `enp3s0f0vN`
  representor into OVS-DOCA as a bridge port.
- An **mlx5 switchdev-mode sysfs setup** (`devlink dev eswitch set pci/... mode switchdev`).

None of these are present in our software lab because there is no DPU
hardware here.

---

## Summary

| Concern | Software lab (this assignment) | DPU-accelerated target |
|---|---|---|
| Where is the OVS bridge? | On the k3s host | On the DPU OS, controlled by OVS-DOCA |
| What connects VM to bridge? | veth pair, one leg in pod, one on `br-ovs` | PCIe VF + representor netdev |
| How does the guest see it? | virtio-net via tap (managedTap binding) | virtio-net via vDPA / vfio-pci |
| Where do flow matches run? | Kernel OVS on the host CPU | eSwitch hardware (DPU-side ASIC) |
| What does `ovs-ofctl dump-flows` show? | Kernel datapath flows | `system@ovs-doca` datapath with HW offload actions |
| What new cluster resources appear? | — | SR-IOV device plugin, NIC Feature Discovery, switchdev setup |

The lab we built is the **reference datapath** — same OpenFlow semantics,
same OVS CLI, same Multus/NAD topology, same KubeVirt interface model.
The DPU version replaces the kernel OVS datapath with the eSwitch + OVS-DOCA
and replaces veths with PCIe VFs, while leaving the Kubernetes-facing
manifests recognizably similar (a `type: sriov` NAD + a binding plugin that
speaks vDPA).
