# From a software OVS datapath to BlueField-3 hardware offload

Shridhar Panigrahi - OPI internship, hands-on assignment 2

This document explains how the datapath I built and verified in this
submission changes when it moves to an NVIDIA BlueField-3 DPU with vDPA and
hardware offload. Every claim about the software side references something
observable in this submission's artifacts; the hardware side is grounded in
how OVS-DOCA and switchdev mode actually work, and I have marked the places
where I am reasoning from documentation rather than from hardware I have
touched.

## 1. What was actually built, precisely

The verified stack looks like this, bottom to top:

- A KinD node (a container) runs Open vSwitch 3.5.0 with a plain bridge
  `br1` and a single NORMAL flow. `verification_flows.json` shows that flow
  with its packet counters incremented by the test traffic.
- Two KubeVirt VMs run CirrOS guests under QEMU. Because there is no KVM
  inside Docker Desktop on macOS, the guests run in TCG emulation - every
  guest instruction is software-translated. Each VM's virtio-net device is
  emulated by QEMU in userspace.
- ovs-cni attaches each VM's launcher pod to `br1`: for each pod it creates
  a veth pair, one end in the pod's network namespace (where KubeVirt binds
  it to the VM via a tap device), the other end plugged into `br1`
  (`verification_flows.json` shows the two veth ports, 13 and 14, on the
  bridge).
- A ping between the guests (10.10.10.11 -> 10.10.10.12, `ping_results.txt`)
  traverses: guest virtio driver -> QEMU emulated NIC -> tap -> pod netns ->
  veth -> OVS bridge -> veth -> tap -> QEMU -> guest. The megaflow samples in
  `verification_flows.json` catch this live: entries keyed on the two guest
  MACs with `eth_type(0x0800)` and climbing packet counts, forwarded between
  OVS ports 2 and 3.

The essential property of this stack: **every single packet is touched by
host CPU multiple times** - in QEMU on both ends, in the kernel's tap and
veth handling, and in the OVS datapath. The first ping took 10.9 ms (ARP
resolution plus cold caches; visible in `ping_results.txt`) and steady state
settled around 2.5 ms, which is the price of a fully software path under
emulation. None of this scales: at line rate on a real NIC this design burns
CPU cores roughly in proportion to packets per second.

## 2. The same datapath on a BlueField-3

Moving this to a BlueField-3 with vDPA and OVS hardware offload is not a
tuning exercise; it relocates almost every component. Layer by layer:

**The virtio device: from QEMU emulation to vDPA.** In my setup, virtio-net
is a QEMU software device. With vDPA (virtio data path acceleration), the
BlueField exposes hardware virtio queues directly: the guest keeps its
completely standard virtio-net driver, but the descriptor rings it fills are
consumed by the NIC hardware itself, not by QEMU. Only the control plane
(feature negotiation, queue setup) goes through software (the kernel vdpa
framework and a small mediation driver). The payload path - the thing my
ping traversed through QEMU twice per packet - simply stops existing in
software. This is the reason vDPA matters over plain SR-IOV passthrough: the
guest image stays hardware-agnostic (same CirrOS, same driver), so live
migration between vDPA and purely software backends remains possible.

**The tap and veth plumbing: from kernel devices to eSwitch representors.**
My veth pairs and taps are kernel constructs stitching namespaces together.
On a BlueField in switchdev mode, the embedded switch (eSwitch) of the
ConnectX side is exposed as a set of representor netdevices, one per VF/vDPA
device. A representor is the control-plane handle for a hardware port: slow
path packets appear on it, and rules attached to it program the hardware.
Where ovs-cni plugged a veth into `br1`, the DPU-side agent plugs the VF's
representor into the OVS bridge. Structurally it is the same operation -
which is exactly why the software exercise transfers - but the port now
stands for a hardware switch port, not a kernel pipe.

**OVS itself: from the host kernel to the DPU ARM cores, with the datapath
in silicon.** My OVS runs entirely on the node with its kernel datapath. On
a BlueField-3 deployment, OVS (the OVS-DOCA build) runs on the DPU's ARM
cores - the host does not run a vswitch at all. And OVS-DOCA's datapath is
not the kernel module: flows are compiled into the eSwitch hardware tables
through the DOCA Flow layer. The processing model I observed in the megaflow
cache carries over conceptually one-to-one:

- First packet of a flow: no hardware match, punted to OVS on the ARM cores
  (the slow path), which consults the OpenFlow tables, decides, and installs
  a hardware flow entry.
- Every subsequent packet: matched and forwarded by the eSwitch at line
  rate. Host and ARM CPUs never see it.

My `verification_flows.json` shows exactly this two-tier structure in
software: the OpenFlow table (`NORMAL`) consulted once per flow, and the
megaflow cache short-circuiting subsequent packets. Hardware offload replaces
the megaflow cache tier with silicon. On real hardware the verification
command changes accordingly: `ovs-appctl dpctl/dump-flows type=offloaded`
shows which flows live in hardware, and their counters increment while the
software counters stand still - that stationary software counter is the
proof of offload, and it is the check I would run first.

**The ping, rerun mentally on hardware.** ARP and ICMP packet one take the
slow path through OVS on the ARM cores and install flows; ICMP packets two
through twenty match in the eSwitch and never touch a CPU, host or DPU. RTT
drops from milliseconds (emulation) to tens of microseconds, and - the
actual point - host CPU cost per packet goes to zero. The 2.5 ms steady
state in my `ping_results.txt` is not a number to optimize; it is a number
to delete.

## 3. What changes operationally

- **Provisioning becomes a real lifecycle.** My `cluster_setup.sh` installs
  packages into a container. A BlueField deployment first flashes a BFB
  image to the DPU (over rshim, via the DOCA Management Service), configures
  firmware (SR-IOV, switchdev), and reboots - on fleet scale this is what
  NVIDIA's DPF operator automates, with the DPU ARM cores joining their own
  Kubernetes control plane onto which the OVS/agent stack is delivered.
- **The trust boundary moves.** In my cluster, the node owns its own
  networking. With the vswitch on the DPU, the host becomes untrusted from
  the network's point of view: tenant workloads on the host cannot reach or
  reconfigure the datapath that serves them. This is a security property,
  not just a performance one.
- **The Kubernetes surface barely moves.** This is the part worth noticing.
  The NetworkAttachmentDefinition, the Multus annotation, the KubeVirt
  VirtualMachine object - all of it survives; the interface binding changes
  from a software bridge port to a vDPA/SR-IOV device (device-plugin
  allocated VF plus the DPU-side agent putting the representor on the right
  bridge). The guest image does not change at all. The entire hardware
  transition hides below the same APIs I used against KinD, which is
  precisely the design goal of the DPU model.

## 4. Component-by-component mapping

| This submission (software) | BlueField-3 (offloaded) |
|---|---|
| QEMU emulated virtio-net | vDPA: hardware virtio queues, same guest driver |
| tap + veth pair per VM | VF + eSwitch representor per VM |
| ovs-cni plugging veth into br1 | DPU agent plugging representor into the OVS bridge |
| OVS 3.5 on the node, kernel datapath | OVS-DOCA on DPU ARM cores, datapath in eSwitch silicon |
| Megaflow cache (software fast path) | Hardware flow tables via DOCA Flow (silicon fast path) |
| `ovs-appctl dpctl/dump-flows` | same, plus `type=offloaded` to prove hardware placement |
| Node CPU processes every packet | First packet on ARM cores, rest in hardware, host CPU at zero |
| `apt-get install openvswitch-switch` | BFB flash + firmware config + switchdev, automated by DPF |

## 5. Honest limits of this comparison

I have not run this on a BlueField-3; the hardware half of this document
comes from NVIDIA's DOCA/DPF documentation and from the upstream switchdev
and vDPA kernel models, not from my own measurements. The specific numbers
(microsecond RTTs, line-rate forwarding) are the documented design targets,
not something I verified. What I can vouch for personally is the software
half - every flow, counter and latency figure cited above is in this
submission's captured artifacts - and the structural claim that the
Kubernetes-facing surface survives the transition, because that surface is
exactly what I exercised here.
