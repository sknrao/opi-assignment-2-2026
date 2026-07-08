# OPI Assignment 2 - Cloud-Native OVS Datapath Challenge

This repo runs two real KubeVirt virtual machines on an Open vSwitch bridge
inside a kind cluster. One script builds everything, pings VM-to-VM over two
OVS networks (a plain one and a VLAN-100 one), saves the proof files, and then
checks them with strict PASS/FAIL gates.

```
./cluster_setup.sh   # empty Docker → fully verified datapath in ~7 minutes
```

The key idea: the ping subnets (`10.10.0.0/24` and `10.10.100.0/24`) exist
**only** on OVS bridge `br1`. There is no other path between the VMs on those
subnets. So if the ping works, the traffic must have gone through OVS.

No file here was written by hand. The script generates every artifact on each
run, and it exits with an error if any check fails.

## What the assignment asked for, and where it is

| # | Requirement | File | Proof that it really happened |
|---|---|---|---|
| 1 | Set up a local Kubernetes cluster | [`cluster_setup.sh`](cluster_setup.sh) | [`evidence/setup_run.log`](evidence/setup_run.log) - the full, unedited log of a clean run |
| 2 | Install KubeVirt, Multus, and an OVS CNI | `cluster_setup.sh` | the run log shows each install finishing, and OVS-CNI advertising `br1` as a node resource |
| 3 | Deploy a VM attached to the OVS network | [`manifests.yaml`](manifests.yaml) | both VMs run; Kubernetes reports them attached to `ovs-net` and `ovs-net-vlan100`; `br1` has 4 VM ports, 2 tagged VLAN 100 |
| 4 | Ping over OVS and capture the flow rules | [`ping_results.txt`](ping_results.txt), [`verification_flows.json`](verification_flows.json) | 20/20 packets, 0% loss (on both networks); plus flow counters, the bridge's MAC table, kernel flow entries, and a packet capture |
| 5 | Explain the move to a BlueField-3 DPU | [`dpu_offload_concept.md`](dpu_offload_concept.md) | written around the actual flow entries captured in this repo |

Extra proof lives in [`evidence/`](evidence/): flow and port counters from
before and after the ping, the MAC table, kernel flow entries, a pcap taken on
vm1's bridge port, the VLAN ping output, the raw VM console logs, and the full
run log.

## Pinned versions

Every component is pinned, so the run is repeatable.

| Component | Version |
|---|---|
| kind | v0.32.0 |
| kind node image | `kindest/node:v1.36.1@sha256:3489c767…ebd5` (pinned by digest) |
| Kubernetes | v1.36.1 |
| Open vSwitch (inside the node) | 3.5.0 (Debian package `openvswitch-switch` 3.5.0-1+b1) |
| Multus CNI | v4.3.0 (image pinned - upstream's default YAML uses a floating tag) |
| OVS-CNI | v0.39.0 (image pinned - upstream's default YAML uses `:latest`) |
| KubeVirt | v1.8.4 |
| virtctl | v1.8.4 |
| CirrOS VM image | `quay.io/kubevirt/cirros-container-disk-demo:v1.8.4` |

## How to run

You need: Linux amd64, Docker, `kind`, `kubectl`, `virtctl`, `jq`, and
`python3-pexpect`. If the machine has `/dev/kvm`, the VMs use real hardware
virtualization; if not, the script turns on KubeVirt's supported
`useEmulation` fallback automatically.

**Why Linux is required (macOS and Windows will not work):**

* **The OVS fast path lives in the Linux kernel.** The bridge's packet
  forwarding and the flow entries we capture come from the `openvswitch`
  kernel module on the host. On macOS and Windows, Docker runs inside a small
  hidden VM whose minimal kernel does not ship that module, so `br1` could
  never forward a packet.
* **kind shares the host kernel.** The "node" is just a container; whatever
  the host kernel cannot do, the cluster cannot do either.
* **VMs need `/dev/kvm`.** Hardware virtualization for the CirrOS guests is a
  Linux device. Without it KubeVirt falls back to slow software emulation,
  which the script supports, but only on a Linux host in the first place.
* The script checks all of this up front (`uname`, Docker, required tools)
  and exits with a clear message instead of failing halfway.

```bash
./cluster_setup.sh              # build everything, then verify it
CLEANUP=1 ./cluster_setup.sh    # delete the cluster
```

The script stops with a non-zero exit code if any step or any check fails.

## The proof, pasted from the artifacts

**Ping vm1 → vm2 on the OVS-only subnet** (from [`ping_results.txt`](ping_results.txt)):

```
--- 10.10.0.2 ping statistics ---
20 packets transmitted, 20 packets received, 0% packet loss
round-trip min/avg/max = 0.290/0.588/1.098 ms
```

**Same test over the VLAN-100 network** (from `evidence/ping_vlan100.txt`):

```
--- 10.10.100.2 ping statistics ---
20 packets transmitted, 20 packets received, 0% packet loss
round-trip min/avg/max = 0.208/0.385/0.632 ms
```

**The flow counters on br1 grew while the pings ran** (from
`evidence/flows_before.txt` and `flows_after.txt`):

```
before:  n_packets=76,  n_bytes=6688,   priority=0 actions=NORMAL
after:   n_packets=237, n_bytes=20690,  priority=0 actions=NORMAL   (grew by 161; gate requires ≥ 40)
```

**br1's MAC table learned exactly the MAC addresses we pinned in
`manifests.yaml`** - the plain ports on VLAN 0, the second interfaces on
VLAN 100 (from `evidence/fdb.txt`):

```
 port  VLAN  MAC                Age
    1     0  02:00:00:00:00:02   19
    2     0  02:00:00:00:00:01   16
    3   100  02:00:00:00:01:01    1
    4   100  02:00:00:00:01:02    1
```

**The kernel's flow entries show the VM-to-VM traffic in both directions**
(from `evidence/dpctl_microflows.txt`):

```
in_port(vethb080c4e4), eth(src=02:00:00:00:00:01,dst=02:00:00:00:00:02), eth_type(0x0800), … packets:21, actions:veth1f8c44d2
in_port(veth1f8c44d2), eth(src=02:00:00:00:00:02,dst=02:00:00:00:00:01), eth_type(0x0800), … packets:21, actions:vethb080c4e4
```

Why 21 packets and not 22 (2 warm-up echoes + 20 measured)? The very first
packet of a new flow goes up to the OVS userspace process, which then installs
this kernel entry; the remaining packets hit the fast path. That slow-path /
fast-path split is normal OVS behavior - and the fast-path entry is exactly
the thing a DPU moves into hardware (see
[`dpu_offload_concept.md`](dpu_offload_concept.md)).

**A packet capture on vm1's bridge port recorded the ping itself**
(`evidence/vm1_eth1.pcap`, checked with `tcpdump -r` during the run):

```
20 ICMP echo requests + 20 ICMP echo replies between 10.10.0.1 and 10.10.0.2
```

**All checks passed on the clean run** (from `evidence/setup_run.log`):

```
✔ PASS: ping vm1→vm2: 0% packet loss
✔ PASS: NORMAL flow n_packets delta ≥ 40 (got 161)
✔ PASS: FDB contains vm1 MAC 02:00:00:00:00:01
✔ PASS: FDB contains vm2 MAC 02:00:00:00:00:02
✔ PASS: datapath megaflow vm1→vm2 (pinned MACs, IPv4, 21 pkts ≥ 15)
✔ PASS: datapath megaflow vm2→vm1 (pinned MACs, IPv4, 21 pkts ≥ 15)
✔ PASS: pcap on vm1 port: ≥ 15 ICMP echo requests (got 20)
✔ PASS: pcap on vm1 port: ≥ 15 ICMP echo replies (got 20)
✔ PASS: VLAN-100 ping vm1→vm2: 0% packet loss
✔ PASS: FDB has vm1 eth2 MAC 02:00:00:00:01:01 on VLAN 100
✔ PASS: FDB has vm2 eth2 MAC 02:00:00:00:01:02 on VLAN 100
ALL DATAPATH GATES PASS
```

## A note on `verification_flows.json`

The assignment suggests `ovs-ofctl dump-flows <bridge> --format=json`. That
option does not exist in any released Open vSwitch - `ovs-ofctl` has no
`--format` flag (checked against the OVS source and its
[NEWS file](https://github.com/openvswitch/ovs/blob/main/NEWS)).

So the JSON is produced with `ovs-flowviz`, the official OVS tool for turning
flow dumps into machine-readable output (it ships with OVS 3.4+):

```bash
ovs-ofctl dump-flows br1 | ovs-flowviz openflow json
```

Each entry in the JSON keeps the original `ovs-ofctl` output line in its
`orig` field, plus the parsed match, actions, and counters. The exact command
and timestamp are recorded in
[`evidence/verification_flows.provenance.txt`](evidence/verification_flows.provenance.txt).

## Design decisions

* **The traffic cannot cheat.** The ping subnets exist only on `br1`. The
  default pod network is used only to reach the VM's serial console. Pinging
  the pod gateway or an internet address would never touch the OVS bridge -
  pinging across `10.10.0.0/24` must.
* **Pinned MAC addresses.** The VMs use fixed MACs
  (`02:00:00:00:00:01/02` plain, `02:00:00:00:01:01/02` on VLAN 100), so you
  can follow the same address through `manifests.yaml`, the Kubernetes
  attachment status, the MAC table, and the kernel flow entries.
* **Checks, not claims.** 17 machine-checked gates cover attachment and
  datapath. The script fails loudly unless every one passes.
* **Attachment is proven at two layers.** Kubernetes says the VMs are attached
  (Multus network-status), and OVS says so too (ports on `br1`, VLAN tags,
  learned MACs).
* **The VLAN network adds depth.** The second network makes OVS-CNI create
  real access ports (`tag=100`), and the MAC table's VLAN column proves tagged
  forwarding works - more than a copy-paste flat bridge.

## Limitations

* Linux amd64 only, single-node cluster - by design, to keep it simple.
* The OVS version inside the node comes from the Debian package repo. It is
  recorded (3.5.0-1+b1) but cannot be pinned by digest like the container
  images.
* Because the bridge uses one `actions=NORMAL` rule, the kernel's flow entries
  match on MAC addresses and packet type rather than the full ICMP 5-tuple.
  That is how OVS flow caching works with an L2 pipeline - the packet counts
  (21 per direction) still match the pings exactly.
* There is no real hardware offload here. What changes on a BlueField-3 DPU is
  covered in [`dpu_offload_concept.md`](dpu_offload_concept.md).