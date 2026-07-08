# DPU Hardware Offload Architectural Concept

## Software Bottleneck (current state)
In the local Kubernetes setup deployed for this assignment the networking datapath is entirely host-bound. So when `vm-a` communicates with `vm-b` the packet travels out of a virtual TAP interface across a `veth` pair and into the software-defined `br1` OVS bridge. 

Because this bridge operates in software the host OS kernel must actively process flow tables and execute the switching logic and in a production environment this creates a massive compute tax basically the host CPU is forced to perform heavy networking rather than dedicating its cores to running actual KubeVirt workloads.

## Hardware Transition (target state)
When migrating to an NVIDIA BlueField-3 DPU the objective is to physically separate the data plane from the host CPU while keeping the Kubernetes control plane indentical 

Here is how the architecture shifts to achieve this:

* **vDPA:** Instead of relying on software TAP devices the offloaded architecture uses vDPA and the primary advantage of vDPA is that the guest VMs still use standard `virtio-net` drivers and the guest OS does not need any proprietary vendor software and doesn't even know the underlying hardware has changed however the data plane completely bypasses the host Linux kernel and the packets stream via Direct Memory Access (DMA) directly from the VMs memory into the DPUs ring buffers.

* **SR-IOV & switchdev mode:** At the hardware level we use SR-IOV (Single Root I/O Virtualization) to slice the BlueField-3's physical network interface into multiple Virtual Functions and by configuring the DPU port in `switchdev` mode these physical VFs are exposed back to the host operating system as logical representor ports.

* **Hardware Flow Offloading (OVS-DOCA):** The BlueField-3 features an embedded hardware switch (the eSwitch). The OVS daemon continues to run on the host to manage the control plane but instead of routing packets via the host CPU it uses the NVIDIA DOCA SDK to push the routing rules directly down into the DPU.

## Summary
By combining vDPA, SR-IOV and switchdev mode the orchestrator's perspective remains unchanged and kubeVirt, multus and the OVS CNI continue to manage the environment normally but the crucial difference is that the actual data plane is ripped out of the host CPU and offloaded to the BlueField-3 ASIC allowing packets to be switched at line rate with effectively zero host CPU overhead.