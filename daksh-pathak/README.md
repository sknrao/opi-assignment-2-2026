# Cloud-Native OVS Datapath Challenge

This repository contains my solution for Hands-On Assignment 2. It builds a
small local Kubernetes lab where a KubeVirt virtual machine and a BusyBox test
pod communicate over an Open vSwitch secondary network.

The aim is to make the datapath visible and testable before considering DPU
acceleration. The local lab validates the software OVS path; it does not claim
to implement or validate hardware offload.

## What this submission demonstrates

- A repeatable KinD cluster setup with KubeVirt, Multus, and OVS CNI.
- A CirrOS VM and peer pod attached to the isolated `br-ovs` bridge.
- Fixed secondary-network addresses: `192.168.100.10` for the VM and
  `192.168.100.20` for the peer.
- Successful bidirectional ICMP traffic across the OVS-backed network.
- OVS rules with live counters for both the request and reply directions.
- A documented path from this software design to a possible BlueField-3 vDPA
  architecture.

## Followed approach

1. I started with a small KinD cluster and brought up KubeVirt before adding
   the secondary networking components.
2. I created one isolated OVS bridge and attached both the CirrOS VM and a
   simple peer pod to it through Multus and OVS CNI.
3. I tested connectivity first, then captured separate request and reply flow
   counters so the result did not rely on ping output alone.
4. I could have started with a BlueField-specific design, but no physical DPU
   was available. I therefore validated the underlying software datapath
   locally and kept the BlueField-3 offload work clearly conceptual.
5. I kept each setup stage independently observable so a failure could be
   traced to orchestration, interface creation, OVS attachment, or forwarding.

## Repository contents

| File | Purpose |
| --- | --- |
| `cluster_setup.sh` | Creates or reuses the lab, installs the networking stack, deploys the workloads, runs the ping test, and captures the OVS flows. |
| `manifests.yaml` | Contains the namespace, network add-ons configuration, OVS network definitions, peer pod, and KubeVirt VM. |
| `ping_results.txt` | Raw output from the peer-to-VM ping test. |
| `verification_flows.json` | Machine-readable OVS flow dump captured after the ping. |
| `dpu_offload_concept.md` | Explains the local datapath and how it would conceptually change with BlueField-3, vDPA, switchdev, and OVS-DOCA. |

## How to run or review

The script expects Docker to be running, Internet access, and the following
commands to be available:

```text
docker
kubectl
curl
jq
```

Run the complete lab from the repository root:

```bash
./cluster_setup.sh
```

The script is staged and idempotent, so rerunning it reuses the existing KinD
cluster where possible. It leaves the cluster running after completion for
manual inspection.

For a quick review without rerunning the lab, I suggest this order:

1. Read `ping_results.txt` for the connectivity result.
2. Inspect `verification_flows.json` for the two counted ICMP directions.
3. Review `manifests.yaml` to see how the VM and peer join `br-ovs`.
4. Read `cluster_setup.sh` for the installation and validation approach.
5. Read `dpu_offload_concept.md` for the DPU transition and its limitations.

## Verification artifacts

The saved ping result shows four packets transmitted, four received, and zero
packet loss from the peer to `192.168.100.10`.

The flow JSON contains two priority-200 ICMP rules using cookie `0xc10d2026`.
One matches `192.168.100.20 → 192.168.100.10`, and the other matches the return
direction. Both captured rules have a packet count of four and use the OVS
`NORMAL` action.

These artifacts show that traffic was classified in both directions by OVS,
not simply that the two interfaces existed.

## Local validation versus BlueField-3 scope

The implemented lab is a software datapath running inside a local KinD
environment. KubeVirt provides the VM, Multus requests the secondary network,
OVS CNI connects the workloads, and `br-ovs` performs the switching.

BlueField-3, vDPA, OVS-DOCA, switchdev mode, representors, DMA/IOMMU isolation,
and hardware flow offload are discussed only as the next architectural step in
`dpu_offload_concept.md`. No BlueField hardware was used, so hardware offload
and its performance were not validated here.

## Known limitations

- Docker and network access are required to create the environment and obtain
  the pinned components and images.
- The OVS network is intentionally isolated and has no physical uplink.
- When KVM is unavailable, the script uses KubeVirt software emulation. This
  is suitable for functional validation, not performance measurement.
- The setup installs OVS inside the KinD node and includes a local ARM/TCG
  workaround for Apple Silicon.
- Flow counters and timings are snapshots from one run and should be
  regenerated when validating a new deployment.

## Closing note

My focus in this assignment was to verify each layer separately: VM
orchestration, secondary-network attachment, OVS forwarding, and observable
traffic counters. The DPU document then carries that same layer-by-layer
approach into the hardware-offload design without presenting conceptual work
as a completed hardware test.
