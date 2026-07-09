# Overview of the work I have done.

## Commands to run the VM using the KinD ,and OVS 

```
./cluster_setup.sh
```

### Explaination of the Bash script 
The script contains three helping function which indicates ,step which is going on , info what is going to run and success what has been completely deployed.

As script contain 9 parts:

1. Creating the cluster with name "ovs-test-cluster" , also I passes the YAML config where it assignes the APIserver IP, it's ports, the podsubnet and the servicesubnet.

2. Installing KubeVirt , which is used to teach the K8s how to run the VM, it have some components like , virt-operator , virt-api , virt-controller (brain, when we create VM device where to run , monitoring VM etc task are done.) and virt-handler. For virt-controller I have first run it normally but I get the error where virt-controller is going into the Pending state also the virt-controller is getting into the CrashLoopBackOff state , the GRANT permission and last I added the restart part I specifically added it for the virt-controller because that was only component that was crashing , we can make changes like for every-component , that nice idea for the script but I added for one .

3. Installing CDI , Disk Image Downloader for VM , when we create VM we need and ISO image but CDI automatically downloads it. It has components , operator , apiserver, deployement and upload-proxy.

4. Installing Multus, it is an extra network adapter manager , by default K8s gives each pod one network interface , but it let us attach multiple network . Where it is run in the daemonset , by which every node can create secondary network.

5. Configuring OVS on Host , installing, running and creating the bridge.

6. Installing CNI Container Network Interface plugins are executables that Kubernetes calls to create and manage pod networking. Wheree I installed the archive verison , which has multiple plugins ,bridge, host-local, loopback, portmap, and tuning, as I first not installed it and running my VM that's why I getting Pending or Scheduling status while running the VM , after researching and using AI get to know what is missing in my scrpit , also I added the Linux kernel Bridge inside the KinD , creates the veth one in Host namespace and other in container namespace , inside the container , add veth-kind to br-ovs bridge and bring it up and On host add veth-host to OVS bridge br-ovs.

7. Creating the namespace and adding the network attachment defination , it tells the K8s when pods ask for "ovs-network", it connect tthem to ovs bridge and assign IP from the range.

8. The virtual machine deployement I added in the script as I founded it more automative rather than running the cmds in the terminal , where I added the directory finding part through Internet as first I created a seprate folder for the yaml file , then my VM was not running as I added this after that , I found the Pending error so I deleted that folder and move the manifests.yaml.

9. This part is for the verification whether the nodes, pods, bridge, and VM is running fine or not .

For Ping test I used the cmd form the internet :

```
kubectl run test-ping \
  -n ovs-test \
  --image=busybox \
  --restart=Never \
  --command -- sh -c "ping -c 5 192.168.100.100"

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/test-ping -n ovs-test --timeout=120s

{
echo "=== Ping Test: test-ping pod -> CirrOS VM over OVS-backed interface ==="
echo "=== OVS Network: 192.168.100.0/24 ==="
echo
kubectl logs test-ping -n ovs-test
} > ping_results.txt
```
This Cmd create a pod which I called test-ping and it is created inside the ovs-test namespace, a small linux image container BusyBox is used for the ping test , added the --restart=Never , which tells the K8s don't recreate it if exits as this is for just ping test , --command everything after this flag is treated asthe container cmd where I added bash cmd adding the VM's IP on the OVS backed network, at last , Instead of checking repeatedly yourself, kubectl wait blocks until a condition is met. and output is stored in the ping_results.txt


For Verification.json

```
sudo ovs-ofctl -O OpenFlow13 dump-flows br-ovs > verification_flows.txt
```
The command uses `ovs-ofctl` to retrieve all OpenFlow flow entries from the `br-ovs` bridge using the OpenFlow 1.3 protocol.
The output is redirected and saved into `verification_flows.txt` for verification after that I converted it into the json formate.

In Last I added the dpu_offload_concept.md file as per the task , I gather the infromation from same offical websites of the NVIDIA and used AI for understanding the flow, at end I created the .md but understanding each companent and part then added to the file.

At Last I , done the basic work by myself but the download paths and testing part I used the internet because I don't know from where to download , but I ensure you that the scrpit , .yaml and .md I created by myself with multiple errors , but I research on each things than added in my task.
