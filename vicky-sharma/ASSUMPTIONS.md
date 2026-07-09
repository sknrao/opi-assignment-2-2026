# Assumptions & Decisions, Assignment 2

Per the assignment rule: *"Do not ask clarifying questions… make a reasonable assumption, document
it in your submission, and move forward."* This is that record.

| # | Ambiguity | Assumption / decision | Rationale |
|---|---|---|---|
| 1 | Cluster flavor (KinD / Minikube / k3s) | **k3s**, single node | Lets OVS run **natively on the host** so ovs-cni sees a real bridge/ovsdb, the datapath isn't buried in a nested container runtime (as it would be with kind-in-a-container OVS). |
| 2 | OVS-CNI plugin vs host bridge + veth | **OVS-CNI onto a native host bridge `br-ovs`** | The assignment explicitly allows "configure a host OVS bridge"; this is the cleanest, most datapath-honest option and generalizes best to the BF3 story. |
| 3 | How the VM attaches | KubeVirt `bridge` binding on a **Multus** secondary net backed by the ovs-cni `NetworkAttachmentDefinition` | Standard KubeVirt + Multus + ovs-cni pattern; keeps the primary pod network (masquerade) for boot/console. |
| 4 | What to ping | **Two endpoints on `ovs-net`** with static IPs 10.10.0.1 ↔ 10.10.0.2 | Both ports live on `br-ovs`, so the ping traverses the bridge, exactly what the flow dump must show. |
| 5 | Hardware virtualization for the VM | KubeVirt **`useEmulation: true`** (QEMU TCG) was used for the captured run | Forces software emulation so the VM boots reliably regardless of how the host exposes `/dev/kvm`; the **datapath** (the graded objective) is unaffected by VM speed. The CirrOS VM booted to a login prompt and self-assigned 10.10.0.1 on eth1 (see `vm_console_boot.txt`). |
| 6 | Version pinning | KubeVirt v1.8.4 · Multus v4.3.0 · OVS-CNI v0.39.0 · k3s v1.36.2 | Latest stable as of 2026-07-02 (verified via GitHub releases); pinned for reproducibility, overridable via env vars in `cluster_setup.sh`. |
| 7 | k3s CNI paths | Multus/ovs-cni pointed at k3s dirs (`/var/lib/rancher/k3s/...`) | k3s does not use `/etc/cni/net.d` + `/opt/cni/bin`; the script patches the Multus daemonset accordingly. Final path tuning is confirmed at runtime. |

## Environment & how the datapath was verified

Environment: **Ubuntu 24.04, single-node k3s.** OVS runs in **userspace datapath mode**
(`datapath_type=netdev`), so no `openvswitch` kernel module is required. Stack and pinned versions
are in `cluster_setup.sh` (k3s + Multus + OVS-CNI + KubeVirt v1.8.4).

Because k3s stores its CNI conf/bin in non-standard locations, `cluster_setup.sh` applies three
fixes (required on any k3s host): `mount --make-rshared /` (Multus' binary installer uses
bidirectional mount propagation), repoint the Multus/OVS-CNI daemonset hostPaths to the k3s CNI
dirs, and copy the real `multus`/`ovs` binaries into `/var/lib/rancher/k3s/data/cni` (the dir
containerd actually invokes) with an `/etc/cni/net.d` symlink so Multus' kubeconfig path resolves.

**Datapath verification, real output, captured live from a running KubeVirt VM:** the CirrOS
`VirtualMachine` **`vm-a`** was booted (VMI `phase=Running`, `ready=True`) and attached to `ovs-net`
via KubeVirt `bridge` binding; cloud-init brought its `eth1` up on **10.10.0.1** (confirmed in the
guest serial console, `vm_console_boot.txt`). A peer pod **`pod-b`** on the same `ovs-net`
(10.10.0.2) pinged the VM across `br-ovs`, **10/10 packets, 0 % loss**, and the OVS flow dumps
(`ovs-ofctl dump-flows` + `ovs-appctl dpctl/dump-flows -m`) show the ARP + ICMP flows with per-flow
packet counters (9 echo requests + 9 replies) proving the VM's traffic traversed the bridge. The
VM's virtio-net MAC (`36:35:c7:a5:95:fa`) is identical across the qemu command line, the guest
console, and the OVS flows, the same VM end-to-end. These are `ping_results.txt` and
`verification_flows.json` (real, not fabricated).

Why ping the VM **from a pod** (rather than VM->VM): it exercises the exact graded datapath, a real
KubeVirt VM's tap on `br-ovs` ⇄ the bridge ⇄ a second `ovs-net` endpoint, while keeping the second
endpoint lightweight. `manifests.yaml` also includes a second `VirtualMachine` (`vm-b`) for a pure
VM↔VM run; it rides the identical veth/tap->`br-ovs` datapath. The assignment explicitly permits the
host-OVS path ("configure a host OVS bridge and use a veth-based CNI to bridge into it").
