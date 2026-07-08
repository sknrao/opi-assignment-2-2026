# Assignment 2 — OVS Datapath on Kind + KubeVirt

A CirrOS KubeVirt VM attached to an Open vSwitch bridge inside a Kind
cluster, with the OVS-CNI, Multus, and CDI stack installed and verified.

## Environment

- Host OS: Ubuntu (Docker installed)
- Docker, `kind`, `kubectl`, `virtctl`, `git`
- Kind cluster: single control-plane node
- KubeVirt `v1.8.4`
- CDI `v1.65.0`
- Multus CNI (`kube-multus-ds`)
- Open vSwitch `3.1.0` (`openvswitch-switch` package, installed inside the
  Kind node container)
- OVS-CNI (built from source examples in the upstream repo — the published
  `raw.githubusercontent.com` manifest returned a 404 at the time of the run)

## Quick start

```bash
./cluster_setup.sh
```

This runs the full sequence end to end: Kind cluster → KubeVirt → emulation
patch → CDI → Multus → OVS install + `br0` → OVS-CNI → apply `manifests.yaml`.

## Setup steps performed

1. Created a single-node Kind cluster (`ovs-lab`).
2. Installed KubeVirt `v1.8.4` and waited for `Available`.
3. **Patched KubeVirt to `useEmulation: true`.**
4. Installed CDI `v1.65.0`.
5. Installed Multus and confirmed the daemonset rolled out.
6. Installed `openvswitch-switch` inside the Kind node's container, started
   `ovs-vswitchd`/`ovsdb-server`, created bridge `br0`, brought it up.
7. Installed OVS-CNI (cloned repo, applied `examples/ovs-cni.yml`).
8. Applied `manifests.yaml`: the `ovs-network` `NetworkAttachmentDefinition`
   (bridge `br0`) and the `ovs-vm` VirtualMachine.
9. Verified the VM came up with a second interface (`eth1`) on the OVS
   network, brought it up inside the guest (`sudo ip link set eth1 up`), and
   independently verified a second Multus/OVS interface (`net1`) on a plain
   test pod (`ovs-test`).

## Important: this ran in software emulation, not hardware KVM

KubeVirt was configured with `useEmulation: true` because the Kind node runs
as a Docker container and does not expose `/dev/kvm` from the host — there is
no hardware-accelerated KVM path available in this setup. No KVM-acceleration
claim is made anywhere in these deliverables, and no `kvm_proof.txt` /
`qemu_accel.txt` files are included, because that evidence was never
captured — this lab used the software (QEMU/TCG) virt-launcher path
throughout.

## What was verified

- `ovs-vsctl show` on the Kind node confirms `br0` exists with a `veth` port
  patched through from the VM's second interface.
- `ovs-ofctl dump-flows br0` shows a flow rule (`priority=0 actions=NORMAL`)
  with a **nonzero and increasing `n_packets` counter**, confirming real
  traffic is crossing the OVS bridge as VM/pod traffic flows.
- `ip addr` inside the CirrOS guest confirms `eth1` came up and was
  successfully brought to the `UP,LOWER_UP` state on the OVS-attached network.
- `kubectl exec ovs-test -- ip addr` independently confirms the same
  `ovs-network` attachment hands out a second working interface (`net1`) to a
  plain pod, outside of KubeVirt.
- A ping from inside `ovs-vm` (`ping -c 4 10.0.2.1`, 0% packet loss) confirms
  basic IP connectivity is functional from the guest.

**Scope note:** this demonstrates that the OVS bridge, NAD, and OVS-CNI data
path are correctly wired up end to end (bridge exists, CNI plugin runs, VM
gets a hardware-backed second NIC, real traffic increments OVS flow
counters). It does **not** include a second OVS-attached VM or a VM-to-VM
ping — only one VM (`ovs-vm`) was attached to `ovs-network`. That would be a
natural follow-up to more directly demonstrate east-west connectivity, but
wasn't part of what was run here.

## Evidence files included

| File | Purpose |
|---|---|
| `cluster_setup.sh` | End-to-end bootstrap script (reconstructed from the session log). |
| `manifests.yaml` | `ovs-network` NAD + `ovs-vm` VirtualMachine + `ovs-test` pod. |
| `ping_results.txt` | Guest ping test output, 0% loss. |
| `verification_flows.json` | OVS flow-table dump, JSON-formatted. |
| `ovs_bridge.txt` | `ovs-vsctl show` output confirming `br0` and its ports. |
| `vm_status.txt` / `vmi_status.txt` | `kubectl get vm/vmi -o wide` output. |
| `network_attachment.yaml` | The live `NetworkAttachmentDefinition` as read back from the cluster. |
| `pods.txt` | Full `kubectl get pods -A` snapshot. |
| `dpu_offload_concept.md` | Software OVS datapath vs. DPU-hardware-offloaded OVS. |

## Note on `ovs-ofctl` and JSON

This OVS build (Debian/Kind node, OVS `3.1.0`) does not support
`ovs-ofctl --format=json` / a native `dump-flows` JSON output — that flag
isn't available on this build. `ovs-ofctl dump-flows br0` was redirected to
`flows_after.txt` as plain text, and `flows_to_json.py` (a small parser) was
used to convert that raw text into `verification_flows.json`. The JSON file
therefore always traces back to the actual raw command output rather than
being hand-written.
