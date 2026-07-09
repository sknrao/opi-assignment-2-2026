# ISSUES.md — running list of failures in this lab

This file tracks every failure point we've hit or are still hitting, by
category. **No fixes** — this is just inventory.

Last updated: 2026-07-07 (session 3, end)

## Status overview

| # | Category | Status (current) |
|---|---|---|
| 1 | Multus/OVS-CNI secondary network for KubeVirt | **Working** in production. The lab chain works: `br-ovs` + multus (custom DaemonSet with `/run/openvswitch` mount) + OVS-CNI + KubeVirt `managedTap` binding + `useEmulation: true`. |
| 2 | KVM hardware acceleration inside the launcher pod | **Broken.** `/dev/kvm` is mounted (kubevirt device plugin + cgroup 0660), but libvirt fails with `Permission denied` at `KVM_GET_API_VERSION` ioctl. VM runs on TCG (software emulation) via `useEmulation: true`. Root cause is **unresolved**; we have the workaround. |
| 3 | OVS bridge persistence across host reboot | **Fixed** with a one-shot systemd unit `cluster-setup-restore-bridge.service` plus a small shell script. Without it, `br-ovs` comes back DOWN with no IP after a reboot; with it, the bridge is up and has `192.168.200.1/30`. |
| 4 | KubeVirt `useEmulation: true` workaround | **Working.** When `useEmulation: false`, the launcher pod requests `kubevirt.io/kvm: 1`, the device plugin bind-mounts `/dev/kvm` (we verified the file is mode 0660 qemu:qemu in the pod), but the libvirt call to `KVM_GET_API_VERSION` ioctl fails with `Permission denied`. With `useEmulation: true`, the VM runs on TCG and the chain works. |
| 5 | CirrOS cloud-init `runcmd` not auto-executing | **Unresolved.** On `quay.io/kubevirt/cirros-container-disk-demo` (Linux 4.4.0-28, BusyBox 1.23.2), the userdata's `runcmd` does NOT execute during boot. The VM comes up with eth0 up but with no IPv4. The user must run `ip addr add 192.168.200.2/30 dev eth0; ip route add default via 192.168.200.1 dev eth0` from the VM console. A newer CirrOS image (0.6.3) would likely fix this, but we don't have it cached. |
| 6 | Multus file `00-multus.conf` immutable flag on host | **Resolved.** After a host restart, the multus pod was failing with `operation not permitted` when writing to `/host/etc/cni/net.d/00-multus.conf`. The file had chattr `+i` (immutable). Fix: `chattr -i /etc/cni/net.d/00-multus.conf` (or use the systemd recovery unit which deletes it). |

---

## Category 1: Multus + OVS-CNI + KubeVirt secondary network

**Working state.** The custom Multus DaemonSet (deployed by `install_multus` in `cluster_setup_root.sh`) has the `/run/openvswitch` volume mount, and multus creates `00-multus.conf` in `/etc/cni/net.d/`. The `install_k3s_cni_config` function copies that conf to `/var/lib/rancher/k3s/agent/etc/cni/net.d/`, which is what k3s's kubelet reads. The KubeVirt binding `ovsTap` with `domainAttachmentType: managedTap` creates the VM's tap device; the managedTap bridging does the rest.

**The launcher's `network-status` annotation** (a fact, not an assumption) shows:
- `cbr0:eth0` with the flannel default IP (cluster-default network).
- `vm-lab/ovs-net:pod6b4853bd4f2` with the OVS-CNI secondary network interface, MAC `52:54:00:6c:6f:01`.

**The chain works in production**: `ping 192.168.200.2` returns 4/4 with 0% loss.

---

## Category 2: KVM hardware acceleration in the launcher pod

**Symptom:** With `useEmulation: false` (the KubeVirt default), the launcher pod requests `kubevirt.io/kvm: 1`. The kubevirt device plugin bind-mounts `/dev/kvm` into the pod. The pod has the device file with mode 0660 owned by `qemu:qemu` (matching the launcher's `runAsUser: 107`). Direct test `exec 3</dev/kvm` from bash works. But libvirt's `virHostCPUGetCPUID:1470` fails with `Unable to open /dev/kvm: Permission denied`.

**Root cause analysis (in progress):** the file IS openable; the error is at the ioctl level. Most likely culprit: **cgroup v2 device filter**. The kubevirt device plugin should add the cgroup rule `c 10:232 rwm` (for `/dev/kvm`, major 10, minor 232) to the launcher's cgroup `devices.allow`. We have not yet verified the cgroup rules. Other possible causes: AppArmor/SELinux on the host, or an in-pod seccomp policy that blocks the `KVM_GET_API_VERSION` ioctl.

**Workaround in production:** `useEmulation: true` patches the KubeVirt CR to fall back to TCG (software emulation). The VM boots on `-accel tcg` with a 5–10x slowdown vs. KVM, but the lab is functional. The user can enable KVM by manually removing the patch and restarting the VM, but the KVM ioctl will fail until the cgroup rule is fixed.

**Next investigation steps:**
1. Check the launcher's cgroup: `cat /sys/fs/cgroup/*/devices.allow | head` and `cat /sys/fs/cgroup/*/devices.list | grep 10:232` inside the pod.
2. If cgroup rule missing, the kubevirt device plugin is supposed to add it. If the plugin's `ListAndWatch` response is missing the device path, kubelet won't bind-mount it correctly. The plugin is the everpeace `k8s-host-device-plugin`.
3. If cgroup is fine, check AppArmor/SELinux on the host for `/dev/kvm` denial.
4. If both are fine, the issue is in-pod seccomp: `kubectl exec $P cat /proc/1/status | grep Seccomp`.

---

## Category 3: OVS bridge state after host reboot

**Symptom:** After a host reboot, `br-ovs` comes back in DOWN state with no IP address. The k3s cluster and OVS service are fine; the bridge just doesn't come up automatically.

**Root cause:** OVS doesn't manage host-level IP addresses on bridge interfaces. The `openvswitch-switch.service` is enabled and active, but its ExecStart is `/bin/true` (the OVS service doesn't do anything in newer releases; the OVS daemon runs as a separate unit). The bridge's `up` state and the host IP `192.168.200.1/30` are lost on reboot.

**Fix in production:** a one-shot systemd unit `cluster-setup-restore-bridge.service` runs a small shell script `cluster-setup-restore-bridge.sh` at every boot. The script re-applies `ip link set br-ovs up` and `ip addr add 192.168.200.1/30 dev br-ovs`. The unit's `After=openvswitch-switch.service` dependency ensures OVS is up first.

**Install once:**
```bash
sudo install -m 0755 cluster-setup-restore-bridge.sh /usr/local/bin/
sudo install -m 0644 cluster-setup-restore-bridge.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable cluster-setup-restore-bridge.service
```

**Manual fallback** if the unit is not installed:
```bash
sudo ip link set br-ovs up
sudo ip addr add 192.168.200.1/30 dev br-ovs
```

---

## Category 4: `useEmulation: true` workaround

**Active in production.** The KubeVirt CR is patched with `developerConfiguration.useEmulation: true` and `network.binding.ovsTap.domainAttachmentType: managedTap`. The script's `install_kubevirt` function applies this patch after KubeVirt is Deployed.

**Why this is needed:** KVM acceleration is broken (see Category 2). With `useEmulation: false`, the VM fails to boot because libvirt can't initialize the KVM context. With `useEmulation: true`, KubeVirt uses TCG (software emulation).

**Trade-off:** TCG is much slower than KVM (typically 5–10x for CPU-bound workloads, more for memory-bound). For this lab's CirrOS-based ping/ICMP testing, TCG is fast enough (CirrOS boot + network init in seconds even under emulation).

**Removing the patch** would re-enable KVM, but the KVM ioctl will fail. Don't remove the patch unless you've also fixed Category 2.

---

## Category 5: CirrOS cloud-init `runcmd` not auto-executing

**Symptom:** `manifests.yaml` userdata uses `runcmd:` to set `192.168.200.2/30` on eth0 and add a default route. The VM boots with `eth0` up but no IPv4. Running `ip addr` shows only `inet6 fe80::...`.

**Root cause:** the bundled CirrOS image (`quay.io/kubevirt/cirros-container-disk-demo`, Linux kernel 4.4.0-28-generic, BusyBox 1.23.2) has a stripped-down cloud-init. The `runcmd` block does NOT auto-execute during boot on this image, even with `runAsUser: 0` and SSH key in metadata. We suspect CirrOS 0.3.x's cloud-init requires an SSH key in metadata for `runcmd` to be processed; our Secret has no SSH key.

**Workaround in production:** the `readiness_report` block in `cluster_setup_root.sh` documents the manual step. The user runs `virtctl -n vm-lab console cirros-vm`, logs in as `cirros`/`gocubsgo`, runs `sudo -i`, and configures the IP manually:
```bash
ip addr add 192.168.200.2/30 dev eth0
ip route add default via 192.168.200.1 dev eth0
```

**Alternative fix:** use a newer CirrOS image (e.g., 0.6.3 from `docker.io/cirros/cirros`) where cloud-init's `runcmd` is supported out of the box. We have not switched images because the current image is what the assignment originally used.

---

## Category 6: Multus file `00-multus.conf` immutable flag

**Symptom:** After a host restart, the multus pod was failing with `operation not permitted` on `open /host/etc/cni/net.d/00-multus.conf: operation not permitted`. Multus was crash-looping. Manually checking showed the file had `chattr +i` (immutable) set: `lsattr` showed `----i---------e------- /etc/cni/net.d/00-multus.conf`.

**Root cause:** some earlier session or system tool set the immutable flag. We did not pin down the cause. The `e` flag is `extents` (a normal flag for files on ext4); only the `i` was the issue.

**Resolution:** `chattr -i /etc/cni/net.d/00-multus.conf` removes the flag. The systemd unit `cluster-setup-restore-bridge.service` does not currently run this command, but the operator can run it manually. We did not add the chattr -i step to the unit because the origin of the `+i` is unknown and the unit's other actions are sufficient for the lab to come up.

---

## Order of attack for fixing remaining issues

Per karpathy, the remaining open work is:

1. **KVM acceleration (Category 2):** the cgroup v2 device filter is the most likely cause. Verify by reading `/sys/fs/cgroup/.../devices.allow` inside the launcher pod; if the `10:232` rule is missing, fix the device plugin or add an initContainer to the launcher pod. This requires a test-from-scratch run, not just on the live cluster.

2. **CirrOS `runcmd` (Category 5):** swap to a newer CirrOS image if cloud-init's `runcmd` is needed. This requires modifying `manifests.yaml`.

3. **Multus immutable flag (Category 6):** add `chattr -i` to the systemd unit, but only if the source of the `+i` is identified (otherwise we may be re-applying the flag accidentally).

---

## Files relevant to each issue

| Issue | File |
|---|---|
| 1 (multus/OVS) | `cluster_setup_root.sh` (`install_multus`, `install_k3s_cni_binaries`, `install_k3s_cni_config`) |
| 2 (KVM) | `cluster_setup_root.sh` (`install_kubevirt`), `manifests.yaml` (no fix), investigation needed in launcher's cgroup |
| 3 (OVS bridge) | `cluster-setup-restore-bridge.sh`, `cluster-setup-restore-bridge.service` |
| 4 (useEmulation) | `cluster_setup_root.sh` (`install_kubevirt` patches the CR), live KubeVirt CR |
| 5 (cloud-init) | `manifests.yaml` userdata — manual workaround documented in `cluster_setup_root.sh` `readiness_report` |
| 6 (chattr +i) | `cluster-setup-restore-bridge.sh` (not in scope yet) |

---

## What's working right now (production state, 2026-07-07)

- k3s cluster, single-node, v1.35.6+k3s1. ✓
- `br-ovs` OVS bridge on host, `192.168.200.1/30`. ✓
- CNAO operator running with our custom NAC. ✓
- Multus pod running with `/run/openvswitch` mounted. ✓
- OVS-CNI DaemonSet pod running (CNAO-managed). ✓
- kubemacpool running. ✓
- KubeVirt operator Deployed. ✓
- `ovsTap` binding registered in KubeVirt CR with `domainAttachmentType: managedTap`. ✓
- `kubevirt.io/kvm` device plugin resource advertised (by everpeace plugin). ✓
- The `useEmulation: true` patch is in the KubeVirt CR. ✓
- VM `cirros-vm` is `Running` and `Ready: True` (after `useEmulation` set). ✓
- Host→VM ping works (4/4 received, 0% loss). ✓
- OVS flow dump on `br-ovs` shows traffic (`n_packets` incrementing with each ping). ✓
- A one-shot systemd unit `cluster-setup-restore-bridge.service` exists in the repo for post-reboot bridge recovery. ✓
- `verification_flows.json` and `ping_results.txt` are real outputs from the working lab. ✓

