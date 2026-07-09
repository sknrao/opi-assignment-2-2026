# Hands-On Assignment 2: The Cloud-Native OVS Datapath Challenge

## Objective
Demonstrate an understanding of Kubernetes VM orchestration and Open vSwitch (OVS) datapath fundamentals by deploying a containerized VM attached to an OVS bridge, and conceptualizing its transition to a DPU-accelerated hardware offload model.

## Background
The internship focuses on running VM networking through OVS that is fully hardware-offloaded to a DPU (like the NVIDIA BlueField-3) using vDPA. Before interacting with physical hardware, it is critical to understand the underlying software datapath plumbing in a Kubernetes environment.

## Tasks
1. **Cluster Setup:** Spin up a lightweight local Kubernetes cluster (e.g., KinD, Minikube, k3s).
2. **Networking & Orchestration Stack:**
   * Install KubeVirt.
   * Install Multus CNI.
   * Install and configure an OVS CNI plugin (or configure a host OVS bridge and use a veth-based CNI to bridge into it).
3. **VM Deployment:** Deploy a KubeVirt `VirtualMachine` (e.g., using a CirrOS image) that successfully attaches to the OVS secondary network.
4. **Datapath Verification:** * Execute a ping test to/from the VM over the OVS-backed interface.
   * Capture the OVS flow rules on the underlying node showing the VM's traffic traversing the bridge.
5. **Hardware Offload Conceptualization:** Document exactly how this software datapath changes when moved to an NVIDIA BlueField-3 using vDPA and hardware offload (e.g., OVS-DOCA, switchdev mode).

## Expected Outputs (Machine-Readable Formats Only)
Please submit the following files exactly as named:
1. `cluster_setup.sh`
   * A purely executable Bash script that bootstraps the cluster, KubeVirt, Multus, and the OVS CNI. 
2. `manifests.yaml`
   * A single, valid multi-document YAML file containing all necessary Custom Resources (NetworkAttachmentDefinitions, VirtualMachine, etc.).
3. `verification_flows.json`
   * The raw machine-readable JSON output of the OVS flow dump (e.g., generated via `ovs-ofctl dump-flows <bridge> --format=json`).
4. `ping_results.txt`
   * The raw stdout dump of the ping test.
5. `dpu_offload_concept.md`
   * A Markdown document explaining the architectural shift from the implemented software stack to a hardware-accelerated vDPA architecture on a BlueField-3 DPU.
