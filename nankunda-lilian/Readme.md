
#My attempt for the Hands-On Assignment 2: The Cloud-Native OVS Datapath Challenge

## Objective
Deploy a containerized VM attached to an Open vSwitch (OVS) bridge inside a
local Kubernetes cluster, verify the datapath end-to-end, and document how
the same architecture changes when the switching and virtio-emulation work
moves onto an NVIDIA BlueField-3 DPU via vDPA and hardware offload.

## Architecture
┌─────────────────────────────────────────┐
                     │   KinD node container (K8s control-plane) │
                     │                                           │
   kubectl  ───────► │  kube-apiserver / etcd / scheduler / ...  │
                     │                                           │
                     │  ┌────────────┐        ┌────────────┐     │
                     │  │  vm-a pod  │        │  vm-b pod  │     │
                     │  │ (virt-     │        │ (virt-     │     │
                     │  │  launcher) │        │  launcher) │     │
                     │  └─────┬──────┘        └─────┬──────┘     │
                     │        │ veth               │ veth        │
                     │        ▼                     ▼            │
                     │  ┌───────────────────────────────────┐    │
                     │  │      OVS bridge: br-ovs-lab        │   │
                     │  │      (datapath_type=netdev)         │  │
                     │  └───────────────────────────────────┘   │
                     │        ▲                                  │
                     │        │ managed by                       │
                     │  ┌─────┴──────┐   ┌──────────────┐        │
                     │  │  ovs-cni    │   │   Multus     │       │
                     │  │  DaemonSet  │   │   DaemonSet  │       │
                     │  └─────────────┘   └──────────────┘       │
                     └─────────────────────────────────────────┘



Each VM (`vm-a` at `10.10.10.1`, `vm-b` at `10.10.10.2`) has two network
interfaces:
-`default` — pod-network interface (masquerade), used for management.
- `ovsnet` — a secondary interface attached via Multus, using the OVS CNI plugin, to the host-level OVS bridge `br-ovs-lab`.

 ## Stack Versions
 Component        | Version 

Kubernetes (KinD) | v1.34.0 
KinD              | v0.30.0 |
KubeVirt          | v1.8.4 (software emulation — no `/dev/kvm` inside the KinD node) 
Multus CNI        | `multus-daemonset-thick` (latest) 
OVS CNI           | `k8snetworkplumbingwg/ovs-cni` (latest) |
Open vSwitch      | 3.1.0 (userspace/`netdev` datapath — no kernel module in nested containers)
Guest OS          | CirrOS (`quay.io/kubevirt/cirros-container-disk-demo:latest`) 


## Environment
I have built, worked and verified in GitHub Codespaces (Docker-in-Docker devcontainer).
This environment shapes several of the setup steps below and made life easier through out the process.


## Setup
Run `cluster_setup.sh`, or follow the steps manually:

### 1. Cluster
in the terminal, bash;
kind create cluster --name ovs-lab
kubectl cluster-info --context kind-ovs-lab


### 2. Multus CNI
bash
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset-thick.yml
kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout=180s


### 3. Open vSwitch — installed **inside the KinD node container**
bash
docker exec ovs-lab-control-plane bash -c "apt-get update && apt-get install -y openvswitch-switch"
docker exec ovs-lab-control-plane bash -c \
  "ovsdb-tool create /etc/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema"
docker exec ovs-lab-control-plane bash -c \
  "ovsdb-server --remote=punix:/var/run/openvswitch/db.sock \
    --remote=db:Open_vSwitch,Open_vSwitch,manager_options --pidfile --detach --log-file"
docker exec ovs-lab-control-plane bash -c \
  "ovs-vswitchd --pidfile --detach --log-file -vconsole:off"
docker exec ovs-lab-control-plane bash -c \
  "ovs-vsctl add-br br-ovs-lab -- set bridge br-ovs-lab datapath_type=netdev"


### 4. OVS CNI plugin (rendered from template)
bash
git clone --depth 1 https://github.com/k8snetworkplumbingwg/ovs-cni.git /tmp/ovs-cni
export NAMESPACE=kube-system
export CNI_MOUNT_PATH=/opt/cni/bin
export OVS_CNI_MARKER_HEALTHCHECK_INTERVAL=60
envsubst < /tmp/ovs-cni/manifests/ovs-cni.yml.in > /tmp/ovs-cni/manifests/ovs-cni.yml
kubectl apply -f /tmp/ovs-cni/manifests/ovs-cni.yml


### 5. KubeVirt
Bash
export KUBEVIRT_VERSION=$(curl -sL https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
kubectl apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"
kubectl -n kubevirt patch kubevirt kubevirt --type=merge \
  patch '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
kubectl -n kubevirt wait kv kubevirt for condition=Available timeout=400s


### 6. Deploy the VMs
bash
kubectl apply -f manifests.yaml
kubectl get vmis -w

## Verification

### Ping test
Console into each VM and bring up the OVS-backed interface (CirrOS's
minimal cloud-init support didn't apply our `networkData`/`chpasswd`
configuration, so this is done manually — see Issues below):

bash
virtctl console vm-a
# login: cirros / gocubsgo
sudo ip link set eth1 up
sudo ip addr add 10.10.10.1/24 dev eth1
ping -c 5 10.10.10.2


Result (`ping_results.txt`): **5/5 packets received, 0% loss**,
round-trip 0.294–3.114 ms — confirming end-to-end connectivity across the
OVS bridge between the two VMs.

### Flow dump
bash
docker exec ovs-lab-control-plane ovs-ofctl dump-flows br-ovs-lab


Result (parsed into `verification_flows.json`): a single flow entry
matching all traffic on `table=0` with `actions=NORMAL`, showing
94 packets / 7540 bytes — real traffic (ping + ARP) that traversed
`br-ovs-lab`. (`ovs-ofctl` has no native `--format=json` option for
`dump-flows` in this OVS version, so the raw text output was parsed into
structured JSON with a small Python script rather than fabricated.)



## Hardware Offload: Software Datapath → BlueField-3

See `dpu_offload_concept.md`(./dpu_offload_concept.md) for the full
writeup. Summary: the Kubernetes/KubeVirt/Multus/OVS control-plane
model is unchanged when moving to a BlueField-3 DPU. What changes is the
datapath:

- OVS CNI's veth/tap ports are replaced by **SR-IOV VF representors**
  plugged into the DPU's **eSwitch**.
- `ovs-vswitchd` (often running on the DPU's own Arm cores) offloads
  matched flows directly into **NIC hardware** via **OVS-DOCA** or
  `tc flower`, so only the first packet of a flow touches the host CPU.
- **vDPA** additionally moves virtio-net's data plane (rings, descriptors,
  DMA) into the NIC itself, so QEMU/vhost-net no longer copies every
  packet across the guest/host boundary on the host CPU.

Net effect: host CPU utilization for VM networking becomes roughly flat
regardless of traffic volume, instead of scaling with it.



## Deliverables

 File                      | Description 

1.`cluster_setup.sh`       | Bootstraps KinD, Multus, OVS (in-node), OVS CNI, and KubeVirt 
2.`manifests.yaml`         | `NetworkAttachmentDefinition` + `vm-a` + `vm-b` VirtualMachine CRs 
3.`ping_results.txt`       | Real ping test output, vm-a → vm-b over OVS |
4.`verification_flows.json`| Parsed OVS flow dump showing real traffic on `br-ovs-lab` 
5.`dpu_offload_concept.md` | Architectural writeup: software OVS → BlueField-3 hardware offload 
6.`README.md`              | This document |


## Known Limitations
- VMs run under **KubeVirt software emulation** (no `/dev/kvm` mounted into
  the KinD node), so this validates the *networking* datapath, not KVM
  hardware-accelerated CPU virtualization.
- OVS runs in **userspace/`netdev`** mode rather than the kernel datapath,
  since nested containers can't load `openvswitch.ko`. The control-plane
  and flow-table model are identical either way; only the underlying
  packet-processing implementation differs.
- Manually-started OVS daemons inside the node container do not
  automatically survive a Codespace stop/resume cycle and may need to be
  restarted (see Issues table above).






















  #!/usr/bin/env bash
#
# cluster_setup.sh
#
# Bootstraps: KinD cluster -> Multus CNI -> Open vSwitch (inside the KinD
# node container, userspace/netdev datapath) -> OVS CNI -> KubeVirt
# (software emulation, since no /dev/kvm is passed into the KinD node).
#
# This reflects the actual working sequence used in a GitHub Codespaces
# environment, including the fixes needed along the way:
#   - OVS must be installed/run INSIDE the KinD node container, not the
#     Codespaces host, because hostPath volumes in Kubernetes pods resolve
#     against the node's filesystem.
#   - No kernel module (openvswitch.ko) is available inside containers, so
#     OVS runs its userspace/netdev datapath instead of the kernel datapath.
#   - ovsdb-server needs its database created manually via `ovsdb-tool
#     create` the first time, since Debian's postinst script is blocked by
#     policy-rc.d inside the node container.
#   - ovs-cni.yml is templated (`ovs-cni.yml.in`) and must be rendered with
#     `envsubst`, including CNI_MOUNT_PATH and
#     OVS_CNI_MARKER_HEALTHCHECK_INTERVAL, which are easy to miss.
#

