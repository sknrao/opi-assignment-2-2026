# OVS Datapath Today vs. DPU-Accelerated OVS

## What is a DPU?

A Data Processing Unit (DPU) is a purpose-built network card, such as NVIDIA's
BlueField series, that pairs programmable network hardware (ASIC packet
processing, RDMA, crypto engines) with its own onboard CPU cores running a
full Linux stack. Unlike a plain NIC, a DPU can run entire infrastructure
services — networking, storage, security — independently of the host CPU,
effectively acting as a second, network-facing computer plugged into the
server.

## How OVS works today (software datapath)

Open vSwitch normally runs entirely in host software:

- **`ovs-vswitchd`** is a userspace daemon that holds the full flow table and
  makes forwarding decisions.
- **The kernel datapath** (`openvswitch.ko`) caches recently-seen flows so
  that repeat packets are switched in the kernel without a userspace round
  trip.
- Every packet that misses the kernel cache is punted up to `ovs-vswitchd`,
  matched against the OpenFlow tables, and the resulting action is cached
  back down.

This is exactly the path exercised in this assignment: `br0` lives inside the
Kind node's network namespace, and `ovs-ofctl dump-flows br0` shows the host
CPU's kernel datapath handling every packet that crosses the bridge — the
`priority=0 actions=NORMAL` rule with a rising `n_packets` counter is that
software forwarding path doing its job.

The cost of this model is that **every packet, from every VM or pod on the
host, consumes host CPU cycles** for classification and forwarding, even
though that work has nothing to do with the actual application running in the
VM.

## How OVS + DPU offload works

With a DPU in the picture, the OVS control plane (`ovs-vswitchd`, the flow
tables, OpenFlow logic) still runs — but it runs *on the DPU's own CPU cores*,
and the actual packet-forwarding datapath is pushed down into the DPU's
hardware ASIC instead of the host kernel:

- The host's virtual NIC interfaces are backed directly by the DPU's hardware
  (via SR-IOV virtual functions or virtio-net acceleration), so VM traffic
  goes straight from the guest to the DPU's NIC silicon.
- Flow rules are programmed into the DPU's hardware flow tables (e.g. via
  hardware TC offload or ASAP²-style flow insertion), so once a flow is
  learned, subsequent packets in that flow are switched entirely in hardware
  — the host CPU and even the DPU's own embedded cores are no longer touched
  per packet.
- Only flow *setup* (the first packet of a new flow, control-plane events)
  still involves software; the steady-state datapath is silicon-speed.

## Benefits

- **CPU offload** — host cores stop spending cycles on packet switching and
  are freed up entirely for tenant workloads (VMs, containers).
- **Latency** — hardware-matched flows skip the kernel-to-userspace-to-kernel
  round trips that a software miss can trigger, cutting per-packet latency.
- **Throughput** — ASIC forwarding scales to line rate (tens to hundreds of
  Gbps) in a way that a shared host CPU doing software switching cannot match
  under heavy east-west traffic.
- **Isolation** — because the OVS control plane runs on the DPU rather than
  the host, a compromised or noisy-neighbor VM has a harder time affecting the
  network control plane itself.

## Relation to this implementation

Everything built in this assignment — `br0`, the `ovs-network`
NetworkAttachmentDefinition, and `ovs-vm`'s second interface — is the same
logical datapath a DPU would accelerate; the only difference is *where* the
forwarding decision is executed. Here it happens entirely on the host CPU
via the Linux kernel + `ovs-vswitchd` running inside the Kind node container.
On a DPU-equipped server, the identical bridge/flow model would be
programmed by the same OVS control plane, but the actual per-packet
forwarding would happen on the DPU's ASIC instead of the host CPU — the
`NORMAL` action flow observed in `verification_flows.json` is a stand-in for
what would become a hardware-offloaded flow entry in that scenario.
