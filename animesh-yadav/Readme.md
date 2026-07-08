# OPI Assignment 2 - Cloud-Native OVS Datapath

**Author:** Animesh Yadav  
**Project Objective:** Implementation of a KubeVirt Virtual Machine (VM) orchestrated within a Kubernetes environment, utilizing Open vSwitch (OVS) for networking, with a detailed conceptual analysis of DPU hardware offload.

## Project Overview
This repository contains the deliverables for the OPI Assignment 2. The project demonstrates the lifecycle of a containerized VM in a Kubernetes cluster, specifically focusing on the integration of the Multus CNI and OVS for datapath management.

## Deliverables
*   **`cluster_setup.sh`**: Automated bash script for provisioning the KinD cluster, KubeVirt, Multus, and the OVS CNI.
*   **`manifests.yaml`**: Multi-document YAML defining the `NetworkAttachmentDefinition` and `VirtualMachine` resources.
*   **`ping_results.txt`**: Raw output confirming successful network connectivity and datapath stability.
*   **`verification_flows.json`**: Extracted OpenFlow rules demonstrating the traffic flow across the `br-int` bridge.
*   **`dpu_offload_concept.md`**: Technical design document detailing the transition from the current software-emulated datapath to an NVIDIA BlueField-3 hardware-accelerated vDPA architecture.

## Technical Environment Notes
*   **Orchestration:** KinD (Kubernetes-in-Docker)
*   **Virt Engine:** KubeVirt v1.8.4
*   **Networking:** Multus CNI with OVS backend
*   **Development Constraint:** Environment deployed on WSL2; utilized software emulation (TCG) for KubeVirt virtualization, as documented in the provided technical notes.
