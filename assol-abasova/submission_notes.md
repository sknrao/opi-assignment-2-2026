# Submission Notes — Assignment 2 (partial, per "Approach > Perfection")

## What is delivered and what is real

`cluster_setup.sh` (shellcheck-clean), `manifests.yaml` (validated multi-doc
YAML), `dpu_offload_concept.md`, and two raw artifacts captured live from the
cluster: `verification_flows.json` (actual `ovs-ofctl dump-flows br1` from the
running node, OVS 3.5.0) and `ping_results.txt` — which honestly records a
FAILED ping to the VM. The end-to-end guest ping was not achieved; nothing
here is fabricated.

## What was verified working

Environment: MacBook Air (Apple Silicon, arm64), Docker Desktop, kind.
Verified live on the node: OVS 3.5.0 installed in the kind node with bridge
`br1` (`datapath_type=netdev`, chosen to avoid any kernel-module dependency in
Docker Desktop's VM); internal gateway port `ovs-gw` at 10.10.10.1; Multus +
ovs-cni installed via the Cluster Network Addons Operator; KubeVirt v1.8.4
deployed with software emulation (no /dev/kvm in kind on macOS). On VM
creation, Multus attached the secondary interface from the `ovs-net`
NetworkAttachmentDefinition and ovs-cni plugged the corresponding veth into
`br1` (observed via `ovs-vsctl list-ports br1`: `ovs-gw` + `vethf8518605`;
see `ovs_state.txt`). The bridge forwards traffic under a NORMAL flow with
live packet counters (see `verification_flows.json`).

## Troubleshooting trail (chronological)

1. Docker daemon not running -> started Docker Desktop.
2. Stale incompatible `kind` binary in /usr/local/bin -> replaced via brew.
3. VM in permanent CrashLoopBackOff (~20s cycle) -> diagnosed as an
   architecture mismatch: the CirrOS containerDisk is x86_64-only while the
   node is arm64 (Apple Silicon). Fixed by switching to a multi-arch
   containerdisk (Fedora, then Ubuntu 24.04 for size), pinning a MAC on the
   OVS interface, and using cloud-init network-config v2 matched on that MAC.
   After the fix the launcher pod progressed cleanly (0 restarts) — the crash
   loop was resolved.
4. Final blocker: containerdisk image pulls from quay.io repeatedly stalled
   on the available network (25+ minutes on a single layer, kubelet event
   stuck at "Pulling image"), so the guest never completed first boot, and
   the node->VM ping over br1 could not be captured (Destination Host
   Unreachable — ARP unanswered because no guest is up at 10.10.10.10).

## How I would proceed with more time

Pre-pull the containerdisk on a reliable network (`crictl pull` inside the
node) or mirror it to a local registry, after which the remaining steps are
mechanical: guest boots, cloud-init applies 10.10.10.10/24 to the MAC-matched
NIC, and `cluster_setup.sh` already captures both required artifacts
(node->VM ping across br1, JSON flow dump). Alternatively, rerun unchanged on
a Linux host with KVM, where dropping `useEmulation` makes boot near-instant.
The datapath design itself is validated up to the guest boundary.
