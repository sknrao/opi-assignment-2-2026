# Software OVS DataPath

OVS is a software based network bridge like a real switch , where OVS run is program which runs on the CPU , and consume the CPU usage.

Working of the OVS : 
When Data Packets leaves the VM and go to the network.

1. Packet Created in the VM , where Network Interface write it to a shared memory ring.
2. Then the Host kernel detects the packet on the Network drive.
3. OVS kernel module intercepts it also responsible for the forwarding this packet outside the network , if needed.
4. After interception , OVS serach for the flow table , looks at the source port , MAC addres ,and IP Address.
5. Then OVS finds a match eg " if packets comes form eth0 and has to be send to the eth1".
6. OVS executs actions , which is more CPU works , like copying the packets , modifying the header of the packets.
7. Packets are copied to output interface buffer , which is slow process.
8. At last the NIC transmits packets and it leaves the host.

### Problem :
Every single oacktes goes through these steps, which is all the CPU work , which create latencay and CPU usages also increase , Which results in the Latency of 100 to 150 microsecond per packet , and the CPU usage increase by 80 to 90 % , also one CPU core can't process these all steps.

### Terms which I found important:
1. Flow Table : It is the list of rules which is used by the OVS kernel Modules , as it is like switch that contains the MAC address rules .
2. DataPath : The path form which each data(packet) takes thorugh the VMs to the External network.

# BlueField-3 (Hardware Architecture)
It is a specialized computer that only process network packtes, which make the network management faster , than the OVS software ones.

## Components:

1. Dual Core-ARM CPU : It is a min-computer , which handles the control plane like managemnet and configuration , where it does not process the data packtes of the network, which are fast enough for moving these packtes upto 2GHz.
2. Mellanox Connext ASIC: ASIC standard for the Application Specific Integrated Circuit , which Handles Data Plane , packet processing is done here , also it desgined for specially switching/routing where wirespeed 200Gbps , also the packets are processed with the full network speed , and can perform parallel processing for the better speed.
3. Embedded eSwitch (Elastic Switch): Virtual switch hardware , inside which ASCI is placed , it makes the forwarding decisions and used the "Ternary Content Addressable Memory(Tcam) for flow tables , loopup sums within < 1 nanosecond.
4. On-chip IOMMU : Input Output memory management unit, translattesVM memory address to hardware memory address , also VM does not see the real hardware address , so the translation needed to be secure.

### ASAP2 Technology 
It stands for Accelerated Switching and Packet Processing , it takes OVS flow rules offloads them to the hardware ASIC , which makes it fast and completely opposite of the OVS software , here CPU only manages the rules and ASIC processes these packets accordingly.

# vDPA Framework (Linux Kernel Level)
vDPA is the bridge that lets VMs talk to hardware that doesn't speak VM language. Where VMs only understands the virtio a standard VM network Interface and BlueField-3 understands vendor specifc hardware commands, so vDPA provides the solution as a Translation layer that sits between VM and the BlueField-3.

Key Concept: Virtio Compliance
vDPA devices have:

Virtio-compliant datapath = Packets follow virtio rules
Vendor-specific control path = Hardware-specific commands

## DMA (Direct Memory Access) 
Problems stands when VM memory is Virtual and hardware needs a real addresses , so the vDPA and IOMMU works together here , 
1. VM writes packets to virtual memory address eg: 0x100.
2. IOMMU translates the virtual address to physical address .
3. Hardware DMA reads form the physical address eg : 0x500.
4. And then packets gets transmited.
which provides a benfits taht hardware can directly access the VM memory address and there is zero copy required for the packets ,which makes the system fast.

GPA vs VA (Guest vs Virtual Address)

GPA (Guest Physical Address): What VM thinks is "real" memory
VA (Virtual Address): What's actually in host RAM
vDPA job: Map GPA → VA for hardware

1. VM uses standard virtio interface

   └─ No changes needed to VM

3. vDPA kernel driver translates commands
   └─ Converts virtio → BlueField commands

4. Data path goes directly to hardware
   └─ No CPU involved in packet processing

5. IOMMU protects VM memory
   └─ Hardware can only access assigned memory

# Switchdev Mode & eSwitch
Switchdev Mode is hardware that act likes software switch , Normaally a network switch is a physical device , where switchdev makes hardware Emulate a switch so software can control it like its a switch 

### Legacy Mode 
VF0 traffic  ──┐
VF1 traffic  ──┤──> Host CPU decides where to send
VF2 traffic  ──┘

This represents how CPU should handles each VF's Traffic , where CPU decides whic VF can access the external network, this Modes the process slow as CPU is involed here.

### Switchdev Mode
VF0 traffic ──┐
VF1 traffic ──┼──> eSwitch (hardware) decides
VF2 traffic ──┘
              └──> Host CPU only manages the rules
In this mode the eSwtich handles the traffic , where CPU only adds or removes the rules ,and all the process are done by the eSwitch which flows the rules , it makde the process fatser as hardware decides which VF can access the External network.

## eSwitch Architecture
Embedded Swtich inside BlueFIeld-3 ASIC, what it does as 

Incoming packet
    ↓
eSwitch checks: "Which rule matches this?"
    ↓
eSwitch executes: "Forward to VF1"
    ↓
Packet sent (all in hardware!)
    ↓
CPU never involved (except for management)

VF Representors
VF stands for Virtual Functions , where a interface inside a VM used by the VM to acces the external network , where Representor is the interface in host used for management.
Think it as when we add an OVS rule to the Representor , the eSwtich hardware learns it and process packets accordingly.

Configuration steps:
```
# Enable switchdev mode
devlink dev eswitch set pci/<ID> mode switchdev
```
It creates the representors like enp4sf0_0 or 0_1 etc.

```
# Add OVS rules to representors
ovs-vsctl add-port br0 enp4s0f0_0
ovs-ofctl add-flow br0 "in_port=1,actions=output:2"
```
Hardware learn these rules and executes it.

# OVS-DOCA: Hardware Offload

NVIDA provides three OVS flavors , for different uses cases:

### OVS-kernel:
Currently By Default OVS use it where it is present in Linux Kernel , and it is exectuted by the CPU-based processing , which slow as CPU-limitations , also it used the legacy mode.

### OVS-DPDK:
It is Intermediiate Performance , where it present at the Userspace in higher performance than kernel , it is still exectuted as CPU-Based but in optimized way , where speed is better than kernel , and the CPU usages is 1 Gbps and 60-70% , also throughput is 20-50 Gbps , it is performance focused deployement , where it by-passes the kernel as the DPDK does , but still it uses the Legacy mode.

### OVS-DOCA
It proivde the Maximum Performance , where it is present at the hardware ASIC , and executed on the BlueField-3 eSwtich hardware , where the wirespeed is upto 200Gbps and CPU usages is less than 1% .

## OVS-DOCA : 
It is a datapath Interface (DPIF) for OVS that leverages NVIDIA DOCA libraries to offload packet processing to hardware ,It preserve same OpenFlow API , CLI and data interfaces as OVS-DPDK and OVS-Kernel , but executes flows in hardware instead of software.

### Flow Offloading Process:
1. Administrator adds OVS flow , commands like:
```
ovs-ofctl add-flow br0 "in_port=1,actions=output:2"
```
2. OVS-DOCA passes to NVIDIA DOCA Flow Library , wheere Flow rule received by DOCA abstraction layers and DOCA determines hardware capabilities.
3.DOCA translates to hardware instructions and converts abstract OpenFlow rule -> BlueField eSwitch instructions and optimizes for hardwarre constraints
4.BlueField-3 eSwitch programs hardware , where eSwitch TCam is updated with the new rules and hardware gets ready to process matching packets.
5.Packets processed in hardware , all matching packets forwarded by eSwtich and zero CPU involvement per packet and only CPU overhead is for rule management.

OVS-DOCA per-allocation offload structures
Hardware reserves space for rules before they;re needed , when we add a flow, hardware space already allocated , and results Fast insertion speed.

Defaultly it configure 250K connections offloadable by default and configurable upto 2M connections and pre-allocated containersfor flow rules.

# Datapath Transformation 

OVS-Kernnel

	VM (CirrOS Linux)
	ping 8.8.8.8
	Packets written to virtio-net
	
	|
	v
	
	Host Kernel 
	
	1. OVS Module Reciveces Packets, where network drive detects packet in shared memory ring.
	2. Flow table lookup , where CPU extracts packet headers calaculates hash in hash(in_port,MAC) , then CPU searches kernel memory flow table and L3 cache access it
	3. Match executed , CPU finds matches rules "in_port=eth0" -> "forward to eth1", where CPU modifies packets of needed else updates the checksum and CPU decrements TTL.
	4. Packet copy , 1st copy VM memory -> kernel buffer , 2nd copy Kernel buffer -> NIC buffer , then memory stall and wait for memory write.
	
	|(DMA by NIC)
	v
	Physical Network Interface Card , finally transmits packet via DMA
	

Hardware Offload Datapath in OVS-DOCA on BlueField-3

	VM (CirrOS Linux)
	ping 8.8.8.8
	Packets written to virtio-net
	
	|
	v
	
	vDPA Kernel Translation Layer
	
	|-Translates virtio cmd to hardware formate
	|-Maps VM memory (GPA)->hardware memory 
	|-Updates IOMMU translation table
	|_Minimal CPU overhead 

	|
	v
	
	BlueField-3 DPU
	
	1. eSwitch flow lookup , uses TCam and parallel hardware search and no CPU involved
	2. In ASIC pipline the Match-Action Execution , where ASIC executes forward to output port , it modifies field if needed , calculates checksum and parallel ASIC pipeline processess packets.
	3. Zero Copy Direct DMA , where ASIC reads directly form VM memory , ASIC writes directly to NIC buffer where NO CPU copies involved
	
	|(Direct to NIC)
	v
	Physical Network Interface Card , finally transmits packet via DMA

# Key Architectual Differences

## 1. Packet Processing Location

Software : Packet -> [Host CPU: lookup, execute, copy] -> Network

Hardware : Packet -> [Blue-Field ASIC: lookup, execute, copy] -> Network

## 2. Flow Table Implementation

Software: 
Flow table: Kernel memory (virtual address space)
Lookup: CPU hash calculation + memory access
Speed: O(1) average, but 100+ nanoseconds per lookup
Cache impact: High (causes L3 misses)
Limitation: Sequential (one lookup at a time)

Hardware:
Flow table: ASIC eSwitch TCam (hardware memory)
Lookup: Parallel hardware comparison
Speed: <1 nanosecond per lookup (parallel)
Cache impact: None (independent of CPU cache)
Benefit: Multiple lookups in parallel

## 3. Data Copy

Software:
VM memory → Kernel buffer → NIC buffer → Network
(Multiple copies, CPU involved)

Hardware:
VM memory → BlueField DMA → Network
(Direct, zero-copy)

## 4. Application Transparency

VM Interface:     virtio-net (SAME as before)
OVS API:          OpenFlow (SAME as before)
Host Tools:       ovs-ofctl (SAME as before)
Behavior:         Rules execute in hardware (DIFFERENT!)

Result: Upgrade to OVS-DOCA, flows execute 20-40x faster
        No application changes required!

# Conclusion
The transformation form software OVS to hardware-accelerated OVS-DOCA on BlueFIeld-3 represents a fundamental architectural shift in how packet processing is performed in cloud intrastructure.
This movement of packet processing form gerneral-purpose CPU to dedicated ASICs represents the future of cloud networking , provides effciency , sustinability , scalability and transparency.
