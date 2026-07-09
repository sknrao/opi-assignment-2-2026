# The Cloud-Native OVS Datapath Challenge

This repository contains a fully automated, production-grade setup to deploy KubeVirt Virtual Machines attached to an Open vSwitch (OVS) secondary network bridge using Multus CNI. It serves as a foundation for understanding vDPA hardware offload on NVIDIA DPUs.
<img width="2098" height="750" alt="image" src="https://github.com/user-attachments/assets/1080cc04-b256-40d3-bc10-4fc91b6676fd" />


---

## Prerequisites

Before starting, ensure you are running on a Linux machine (Native Ubuntu is highly recommended for KVM hardware virtualization speed) or Windows WSL2 with Docker Desktop.

You only need one thing running:
- **Docker** (Ensure the Docker daemon is started)

*Note: The setup script will automatically detect and download all missing CLI tools (like `kind`, `kubectl`, and `virtctl`) locally to save you time!*

---

## One-Click Automated Setup

We have engineered an advanced 13-step idempotent pipeline that handles the entire lifecycle automatically:

1. **Validation**: Checks system resources and prerequisites.
2. **Environment**: Safely cleans up old deployments and builds a fresh Kubernetes `KinD` cluster.
3. **Network**: Installs Open vSwitch on the worker nodes, followed by Multus CNI and the OVS CNI plugin.
4. **Virtualization**: Deploys the KubeVirt virtualization engine.
5. **Workload**: Automatically deploys two VMs (`test-vm-1` and `test-vm-2`) and connects them to the secondary OVS datapath.
6. **Verification**: Uses `sshpass` to perform an automated guest-level ICMP ping test directly from `test-vm-1` to `test-vm-2` across the OVS bridge.
7. **Evidence Collection**: Captures the ping output and extracts the highly detailed OVS flow and MAC learning tables.

### How to Run:
Simply open your terminal in this directory and execute:
```bash
bash cluster_setup.sh
```


Sit back and watch the pipeline build your cluster and verify the datapath!
<img width="1175" height="774" alt="Screenshot (3357)" src="https://github.com/user-attachments/assets/50ea2edc-666a-4250-a8b2-9f8691cd9bd5" />
<img width="1920" height="1035" alt="Screenshot (3345)" src="https://github.com/user-attachments/assets/140e1db7-7409-4744-8d28-d413554f905d" />
---

## Expected Automated Outputs

Once the script completes, it will automatically generate the required verification files in your folder:

1. **`ping_results.txt`** 
   - Proves guest-to-guest connectivity with 0% packet loss.
2. **`verification_flows.json`** 
   - A detailed JSON dump containing the OVS flow rules, bridge configurations, learned MAC addresses, and capture metadata.

*(You can view these files directly to verify the success of the datapath!)*
<img width="1067" height="994" alt="Screenshot (3356)" src="https://github.com/user-attachments/assets/0c27d44f-2aba-4c53-9e34-665fc148b7a0" />

## Ping_result.txt and verification_flows.json
<img width="1147" height="747" alt="Screenshot (3358)" src="https://github.com/user-attachments/assets/1cb0ab73-ec4c-483a-85ef-f1b160e8962d" />

---

## Cleanup

To safely tear down the cluster and wipe the Docker nodes, simply run the built-in self-destruct command:

```bash
bash cluster_setup.sh cleanup
```

---

## Architectural Shift to DPUs

To understand *why* we built this software datapath, and how this exact Kubernetes topology translates to blazing-fast hardware acceleration using an **NVIDIA BlueField-3 DPU, vDPA, and OVS-DOCA switchdev mode**, please read the included architectural document:

👉 [Read the DPU Offload Concept Document](./dpu_offload_concept.md)
