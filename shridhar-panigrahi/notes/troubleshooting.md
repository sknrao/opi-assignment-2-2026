# Troubleshooting log

Problems hit while building this, in order, with how each was diagnosed and
what fixed it. Kept because the debugging is half the value of the exercise.

## 1. ovs-cni marker crashlooping on startup

The marker container printed its own usage text and died. First log line:
`invalid value "" for flag -healthcheck-interval: parse error`. Cause: the
upstream manifest template (`manifests/ovs-cni.yml.in`) leaves
`${OVS_CNI_MARKER_HEALTHCHECK_INTERVAL}` to be substituted and my first
render did not set it, so the flag was passed empty. The template also pins
`nodeSelector kubernetes.io/arch: amd64`, which would have kept the pod off
this arm64 node entirely. Fix: render with an explicit interval (60s) and
drop the arch pin (the ghcr.io image is multi-arch; verified with
`docker manifest inspect`). The corrected manifest is inlined in
`cluster_setup.sh`.

## 2. VMs crashlooping before the guest ever started

`kubectl get events` showed virt-handler failing with: `failed to set MTU on
tap device named tap0. Reason: invalid argument` while creating the tap for
the default pod network with `--mtu 65535`. Docker Desktop's VM gives pod
interfaces a 65535 MTU, which is above the kernel's limit for tap devices,
so KubeVirt's attempt to mirror the pod MTU onto the tap failed. Fix that
also simplified the design: drop the pod-network interface from the VMs
entirely and attach them only to the OVS secondary network (MTU 1500). The
VMs exist to demonstrate the OVS datapath; they never needed the pod
network, and cloud-init NoCloud is disk-based so it works without one.

## 3. The aarch64 emulation catch-22

With networking fixed, libvirt refused to define the domain: `CPU mode
'host-passthrough' for aarch64 qemu domain on aarch64 host is not supported
by hypervisor` - under TCG emulation (no KVM inside Docker on macOS) a
passthrough CPU model is impossible. Setting an explicit model in the VM
spec was rejected from the other side: KubeVirt's arm64 admission webhook
answers `currently, host-passthrough is the only model supported on Arm64`.
So the API refuses everything except the one value the hypervisor refuses.
Fix: enable the `Sidecar` feature gate and attach a sidecar hook (ConfigMap
script, `sidecar-shim` image) that rewrites the generated domain XML,
replacing `host-passthrough` with `maximum` (QEMU's "best available under
this accelerator" model) after validation but before the domain is defined.
Both VMs booted on the next attempt.

## 4. The flow dump JSON that does not exist

The assignment suggests `ovs-ofctl dump-flows <bridge> --format=json`. On
Open vSwitch 3.5.0 that option does not exist: `ovs-ofctl: unrecognized
option '--format=json'` - `--format` belongs to the OVSDB tools
(`ovs-vsctl`), not the OpenFlow CLI. Per the ground rules I made an
assumption and documented it inside the deliverable itself:
`verification_flows.json` contains the OpenFlow dump parsed into JSON with
every raw line preserved, datapath megaflow samples captured during a live
ping (these show the actual VM MACs being forwarded between bridge ports),
and the native-JSON OVSDB views of the bridge, ports and interfaces.

## Environment note

Everything above ran on an Apple-silicon Mac (M4, Docker Desktop), which is
why emulation quirks feature so heavily. On a Linux host with KVM, items 2
and 3 would not occur (KVM allows host-passthrough and pod MTUs are sane),
and `cluster_setup.sh` should run with fewer surprises. I kept the fixes in
because a reviewer on similar hardware will hit identical walls.
