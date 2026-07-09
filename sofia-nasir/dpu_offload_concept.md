# Architectural Shift: Software OVS to DPU-Accelerated vDPA Hardware Offload

This document provides a highly detailed architectural specification explaining the shift from a software-defined Open vSwitch (OVS) datapath running on host CPU cores to a hardware-accelerated datapath using an **NVIDIA BlueField-3 Data Processing Unit (DPU)**.

---

## 1. Executive Summary & Datapath Comparison

Our local KinD environment runs Open vSwitch in the Linux kernel on the host CPU. Under heavy virtualization workloads, the host CPU spends massive cycles parsing packet headers, looking up flow tables, and context switching between QEMU user space and Linux kernel space.

By migrating to an **NVIDIA BlueField-3 DPU**, we offload the entire data plane to the DPU's silicon. The host CPU is bypassed for network traffic, reducing x86 overhead to near **0%** while boosting network performance to line-rate (100G/400G).

### Feature Comparison Matrix

| Metric / Feature | Software OVS Datapath (Current) | DPU-Accelerated vDPA (Proposed) |
| :--- | :--- | :--- |
| **Data Plane Driver** | Host Kernel OVS module | DPU eSwitch ASIC (Silicon) |
| **Host CPU Utilization** | High (grows linearly with packet rate) | Near 0% ( fully offloaded to DPU) |
| **Throughput** | Limited by CPU polling (~10-25 Gbps) | Line-rate (100Gbps / 400Gbps) |
| **Latency** | Milliseconds/Microseconds (context switches) | Sub-microsecond (Hardware switching) |
| **VM Driver Model** | Standard `virtio-net` | Standard `virtio-net` (No proprietary drivers!) |
| **Live Migration** | Supported natively | Fully Supported (via vDPA abstraction layer) |

---

## 2. System Architecture & Packet Flow

The diagrams below contrast the packet processing paths of the CPU-heavy software datapath against the direct DPU-accelerated hardware path.

### A. Software-Defined Datapath (CPU Bound)
```
[ KubeVirt VM 1 ] (Guest Space)
      │  (Virtio Descriptor Ring)
      ▼
[ Host QEMU/KVM Process ] (User Space)
      │  (Unix Socket / Tap Protocol)
      ▼
[ Linux Kernel Space ] 
  ├── [ Tap Device (vnet0) ]
  └── [ OVS Kernel Datapath Module ] <───► [ Host CPU (Interupt Handling) ]
      │
      ▼ (Switching & Encapsulation)
[ Physical NIC ] ───► Wire
```

### B. DPU-Accelerated vDPA Datapath (Hardware Offload)
```
[ KubeVirt VM 2 ] (Guest Space)
      │  (Virtio Descriptor Ring mapped directly to DPU via DMA)
      ▼  (Direct PCIe Gen 5 Interface)
[ NVIDIA BlueField-3 DPU ]
  ├── [ Hardware vDPA Engine ] (Emulates Virtio Ring in Silicon)
  ├── [ ASAP² eSwitch ASIC ] (Matches hardware-offloaded OVS rules via DOCA Flow)
  └── [ ARM Cortex-A78 Cores ] (Runs OVS Control Plane & SDN Agent)
      │
      ▼ (Hardware Switching & Line-Rate Encapsulation)
[ DPU Physical Port ] ───► Wire
```

---

## 3. NVIDIA BlueField-3 Hardware Architecture

The BlueField-3 DPU is a fully integrated system-on-a-chip (SoC) designed specifically for networking, security, and storage offloads.

```
+-----------------------------------------------------------------------+
|                       NVIDIA BlueField-3 DPU                          |
|                                                                       |
|  +--------------------+  +--------------------+  +-----------------+  |
|  |   Control Plane    |  |  Data Plane ASIC   |  |   PCIe Switch   |  |
|  |                    |  |                    |  |                 |  |
|  |  16x ARM Cores     |  |   ASAP² eSwitch    |  |  PCIe Gen 5 x16 |  |
|  |  (Cortex-A78)      |  |   (Flow Engine)    |  |  (to Host CPU)  |  |
|  |  Runs OVS-DOCA     |  |                    |  |                 |  |
|  +---------+----------+  +---------+----------+  +--------+--------+  |
|            |                       |                      |           |
|            +-----------------------+----------------------+           |
|                                    |                                  |
|                                    ▼                                  |
|                          +-------------------+                        |
|                          | vDPA HW Engine    |                        |
|                          +---------+---------+                        |
|                                    |                                  |
|                                    ▼                                  |
|                          [ Physical Ports ]                           |
|                          (100G/200G/400G)                             |
+-----------------------------------------------------------------------+
```

### Main Architecture Blocks:
1. **16x ARM Cortex-A78 Cores:** Used for running control plane agents (like `ovs-vswitchd`, CNI daemons, and security agents) directly on the card under a dedicated DPU Linux OS.
2. **ASAP² (Accelerated Switch and Packet Processing):** A hardware accelerator engine inside the ConnectX-7 network controller portion of the DPU. It parses packet headers and executes switching, routing, ACLs, and NAT directly in silicon.
3. **vDPA Hardware Engine:** Translates the standard virtio queue descriptor rings into hardware commands, executing direct memory access (DMA) transfers between the VM's memory pages and the DPU network interface.

---

## 4. The Role of Mellanox DOCA (Data Plane Offloads)

To program the hardware switch on the DPU, developers use the **NVIDIA DOCA SDK (Documented Open APIs for ConnectX)**. 

### OVS-DOCA Compilation Pipeline:
When an OpenFlow rule is applied via Kubernetes (e.g. mapping `test-vm-1` to `test-vm-2` on our OVS bridge):
1. The **Control Plane** (running on DPU ARM Cores) receives the flow rule from OVN / Kubernetes CNI.
2. **OVS-DOCA** (Open vSwitch compiled with DOCA libraries) intercepts the flow.
3. The rule is compiled into **DOCA Flow** syntax.
4. The **DOCA Flow API** programs the ASAP² hardware tables in the ASIC.
5. The packet datapath is instantly redirected at the hardware level.

---

## 5. Step-by-Step Transition & Implementation Guide

Migrating the Kubernetes workload from the software-based KinD OVS setup to the BlueField-3 DPU infrastructure requires the following system configuration steps:

### Step 1: Configure the DPU in Switchdev Mode
By default, DPU ports behave as standard network interfaces. To offload OVS rules, the DPU's eSwitch must be placed in **switchdev mode**, which exposes **Representor Ports** to the host.

Run on the host:
```bash
# Enable SR-IOV on the DPU device (e.g., pci/0000:03:00.0)
echo 4 > /sys/bus/pci/devices/0000:03:00.0/sriov_numvfs

# Unbind the virtual functions (VFs)
echo 0000:03:00.2 > /sys/bus/pci/drivers/mlx5_core/unbind

# Set the eSwitch mode to switchdev
devlink dev eswitch set pci/0000:03:00.0 mode switchdev
```

### Step 2: Run OVS on the DPU Control Plane
Instead of running OVS in the Kubernetes worker node's kernel, we run `ovs-vswitchd` directly inside the BlueField-3's ARM processor.
- OVS control-plane runs on the ARM cores.
- Using **OVS-DPDK** or **OVS-DOCA**, the OpenFlow rules applied to the bridge are compiled and pushed down into the ASIC flow tables using the Linux Kernel TC (Traffic Control) Flower interface.

```bash
# Add the representor port and VF representor to the OVS bridge on the DPU ARM system
ovs-vsctl add-br br-int
ovs-vsctl add-port br-int pf0hpf         # DPU physical port representor
ovs-vsctl add-port br-int enp3s0f0v0    # VM Virtual Function representor
```

### Step 3: Configure KubeVirt and vDPA CNI
To connect KubeVirt VMs to the DPU, we replace the `ovs-cni` with the **SR-IOV Network Device Plugin** configured for `vhost-vdpa`.

1. **Deploy the SR-IOV Device Plugin** with the following config map:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: sriovdp-config
  namespace: kube-system
data:
  config.json: |
    {
      "resourceList": [
        {
          "resourceName": "vdpa_nic",
          "selectors": {
            "vendors": ["15b3"],
            "devices": ["101e"],
            "drivers": ["mlx5_core"],
            "vdpaDrivers": ["vhost_vdpa"]
          }
        }
      ]
    }
```

2. **Define the NetworkAttachmentDefinition** in Kubernetes:
```yaml
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: vdpa-network
  namespace: default
spec:
  config: '{
    "cniVersion": "0.4.0",
    "name": "vdpa-network",
    "type": "sriov",
    "vlan": 100
  }'
```

3. **Deploy the KubeVirt VM** referencing the vDPA hardware device:
```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: test-vm-dpu
spec:
  running: true
  template:
    spec:
      domain:
        devices:
          interfaces:
          - name: dpu-net
            sriov: {} # Direct SR-IOV/vDPA pass-through request
        resources:
          requests:
            memory: 2Gi
            cpu: 2
            mellanox.com/vdpa_nic: "1" # Requests 1 vDPA resource slot
      networks:
      - name: dpu-net
        multus:
          networkName: vdpa-network
```

---

## 6. Architectural Benefits of vDPA

- **Standardization:** Unlike pure SR-IOV which bypasses virtio and requires hardware-specific VF drivers inside the guest OS, **vDPA utilizes standard virtio drivers**. The VM is unaware it is talking to DPU hardware.
- **Live Migration:** Since the guest VM is using a standard `virtio-net` interface, Kubernetes can freeze the VM, migrate its state to another host, and re-establish the connection to a different BlueField-3 DPU vDPA socket on the target host without dropping connection states.
- **Enterprise Security:** The host hypervisor is completely isolated. If the host x86 CPU is compromised, the network security policies (programmed securely on the DPU ARM cores) remain protected in the isolated hardware domain.