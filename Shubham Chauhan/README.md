# Cloud-Native OVS Datapath

This project demonstrates the deployment of a containerized VM attached to an OVS bridge in a Kubernetes environment, verification of the software datapath, and documentation of the transition to a DPU-accelerated hardware offload model.

## Overview

This implementation demonstrates:
- **KubeVirt** for running virtual machines in Kubernetes
- **Multus CNI** for multi-network pod/VM support
- **OVS-CNI** for attaching VMs to Open vSwitch bridges
- **Whereabouts** for IP address management on secondary networks
- **OVS datapath verification** via ping tests and flow capture
- **DPU offload conceptualization** for NVIDIA BlueField-3 migration

## Implementation

### Cluster Setup

The `cluster_setup.sh` script was used to bootstrap the environment:

- Created a KinD cluster named `ovs-datapath` with Kubernetes v1.30.4
- Installed KubeVirt v1.3.1 with software emulation fallback (KVM unavailable in WSL2)
- Installed Multus CNI v4.1.3
- Installed OVS-CNI v0.36.0 with arm64 node selector removed
- Installed Whereabouts IPAM v0.8.0
- Created the OVS bridge (`br-ovs`) on the KinD node

All components were version-pinned for reproducibility.

### Workload Deployment

The `manifests.yaml` file was applied to deploy:

- `NetworkAttachmentDefinition` (`ovs-net`) with OVS-CNI configuration and Whereabouts IPAM (192.168.100.0/24)
- `VirtualMachine` (`cirros-ovs`) with:
  - Two network interfaces: default pod network (masquerade) and OVS secondary network (bridge)
  - Resource limits: 256Mi memory, 0.25 CPU
  - CirrOS container disk image (v1.8.4)

### VM Status

The VM successfully reached the `Running` state on Ubuntu (WSL2):

```
NAME         AGE     PHASE     IP            NODENAME                     READY
cirros-ovs   2m55s   Running   10.244.0.12   ovs-datapath-control-plane   True
```

The VM was assigned an OVS network IP: `192.168.100.2`

## Verification Results

### Ping Test

A test pod was created on the OVS network and used to ping the VM. The results are captured in `ping_results.txt`:

```
PING 192.168.100.2 (192.168.100.2): 56 data bytes
64 bytes from 192.168.100.2: seq=0 ttl=64 time=0.421 ms
64 bytes from 192.168.100.2: seq=1 ttl=64 time=0.215 ms
64 bytes from 192.168.100.2: seq=2 ttl=64 time=0.187 ms
64 bytes from 192.168.100.2: seq=3 ttl=64 time=0.201 ms

--- 192.168.100.2 ping statistics ---
4 packets transmitted, 4 packets received, 0% packet loss
round-trip min/avg/max = 0.187/0.256/0.421 ms
```

**Result:** 0% packet loss confirmed across the OVS-backed interface.

### OVS Flow Capture

OVS flow rules were captured from the `br-ovs` bridge and saved to `verification_flows.json`:

```json
[
  {
    "table": 0,
    "cookie": "0x0",
    "duration": 2380.928,
    "n_packets": 61,
    "n_bytes": 4434,
    "idle_age": 30,
    "priority": 0,
    "match": {},
    "actions": "NORMAL"
  }
]
```

**Result:** The bridge is forwarding traffic with a NORMAL action (L2 flooding). The packet counters (61 packets, 4434 bytes) confirm that VM traffic is traversing the OVS datapath.

## Deliverables

| File | Description |
|------|-------------|
| `cluster_setup.sh` | Executable Bash script to bootstrap cluster, KubeVirt, Multus, and OVS CNI |
| `manifests.yaml` | Multi-document YAML with NetworkAttachmentDefinitions and VirtualMachine |
| `verification_flows.json` | OVS flow dump showing VM traffic traversing the bridge |
| `ping_results.txt` | Ping test output showing 0% packet loss across OVS interface |
| `dpu_offload_concept.md` | Markdown explaining the shift to BlueField-3 vDPA hardware offload architecture |

## Platform-Specific Notes

### macOS/arm64

KubeVirt VMs with bridge binding fail due to tap device MTU 65535 being invalid on macOS/arm64. This platform limitation was documented but the assignment was completed on Ubuntu (WSL2) where the VM successfully booted.

### Ubuntu/WSL2

The verification was performed on Ubuntu (WSL2 on Windows). No KVM hardware virtualization is available in WSL2, but KubeVirt's software emulation worked correctly. The VM booted in 2-5 minutes and fully functioned for datapath verification.

## Teardown

To remove the cluster and all resources after review:

```bash
kind delete cluster --name ovs-datapath
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │   KubeVirt   │  │    Multus    │  │   OVS-CNI    │      │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘      │
│         │                 │                 │              │
│         ▼                 ▼                 ▼              │
│  ┌─────────────────────────────────────────────────────┐  │
│  │              VirtualMachine (cirros-ovs)             │  │
│  │  ┌─────────────┐  ┌─────────────┐                  │  │
│  │  │ eth0 (pod)  │  │ net1 (OVS)  │                  │  │
│  │  └──────┬──────┘  └──────┬──────┘                  │  │
│  └─────────┼────────────────┼──────────────────────────┘  │
│            │                │                              │
│  ┌─────────▼────────────────▼──────────────────────────┐  │
│  │              KinD Node (ovs-datapath-control-plane) │  │
│  │  ┌──────────────────────────────────────────────┐  │  │
│  │  │           OVS Bridge (br-ovs)                │  │  │
│  │  │  Flow rules: NORMAL action (L2 flooding)    │  │  │
│  │  └──────────────────────────────────────────────┘  │  │
│  └─────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## DPU Offload Concept

The `dpu_offload_concept.md` document describes how this software OVS datapath would migrate to a hardware-offloaded architecture on NVIDIA BlueField-3:

- **switchdev mode** exposes the embedded switch to Linux as representor ports
- **SR-IOV VFs** provide hardware-backed virtual functions
- **vDPA** accelerates virtio datapath without guest OS changes
- **OVS-DOCA** offloads OVS datapath pipeline to DPU hardware
- **TC flower classifier** enables kernel-level flow offload

## Troubleshooting

### VM stuck in Scheduling phase

Check if OVS-CNI daemonset is running:

```bash
kubectl get daemonset ovs-cni-amd64 -n kube-system
```

If not running, ensure the node selector was removed for arm64:

```bash
kubectl patch daemonset ovs-cni-amd64 -n kube-system --type='json' \
  -p='[{"op": "remove", "path": "/spec/template/spec/nodeSelector/kubernetes.io~1arch"}]'
```

### OVS bridge not found

Verify the bridge exists on the KinD node:

```bash
NODE=$(kind get nodes --name ovs-datapath | head -n1)
docker exec $NODE ovs-vsctl show
```

If missing, run the cluster setup script again.

### Pod cannot get OVS IP

Check whereabouts IPAM is running:

```bash
kubectl get daemonset whereabouts -n kube-system
```

Verify the NetworkAttachmentDefinition has IPAM configured:

```bash
kubectl get networkattachmentdefinition ovs-net -o yaml
```

## Ownership

This project is part of an assignment for the Open Programmable Infrastructure (OPI) internship program under the LFX Mentorship program.
