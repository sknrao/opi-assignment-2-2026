<!-- code space -->

Checked docer verion: 29.3.0-1
APU vcurl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.30.0/kind-linux-amd64
chmod +x ./kinda
sudo mv ./kind /usr/local/bin/kind
kind version


 Version:           29.3.0-1
 API version:       1.54
 Go version:        go1.26.0
 Git commit:        5927d80c76b3ce5cf782be818922966e8a0d87a3
 Built:             Fri Mar  6 18:50:47 2026
 OS/Arch:           linux/amd64
 Context:           default

Server:
 Engine:
  Version:          29.3.0-1
  API version:      1.54 (minimum version 1.40)
  Go version:       go1.26.0
  Git commit:       83bca512aa7ffc1bb4f37ce1107e0d3e3489ad43
  Built:            Fri Mar  6 18:29:13 2026
  OS/Arch:          linux/amd64
  Experimental:     false
 containerd:
  Version:          2.2.1-1
  GitCommit:        dea7da592f5d1d2b7755e3a161be07f43fad8f75
 runc:
  Version:          1.4.0-2
  GitCommit:        8bd78a9977e604c4d5f67a7415d7b8b8c109cdc4
 docker-init:
  Version:          0.19.0
  GitCommit:        
@Nandalily ➜ /workspaces/opi-assignment-2-2026 (main) $ curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubecctl /usr/local/bin/kubectl
kubectl version --client
rm kbectlc^C
@Nandalily ➜ /workspaces/opi-assignment-2-2026 (main) $ cd nankunda-lilian/
@Nandalily ➜ /workspaces/opi-assignment-2-2026/nankunda-lilian (main) $ curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
rm kubectl
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100 56.7M  100 56.7M    0     0   122M      0 --:--:-- --:--:-- --:--:--  122M
Client Version: v1.36.2
Kustomize Version: v5.8.1
@Nandalily ➜ /workspaces/opi-assignment-2-2026/nankunda-lilian (main) $ curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.30.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
kind version
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100    97  100    97    0     0    294      0 --:--:-- --:--:-- --:--:--   294
  0     0    0     0    0     0      0      0 --:--:-- --:--:-- --:--:--     0
100 10.5M  100 10.5M    0     0  14.3M      0 --:--:-- --:--:-- --:--:-- 14.3M
kind v0.30.0 go1.24.6 linux/amd64
@Nandalily ➜ /workspaces/opi-assignment-2-2026/nankunda-lilian (main) $ ca



Both installed clean — kubectl v1.36.2 and kind v0.30.0. Prerequisites done.

This is the actual "spin up a lightweight local Kubernetes cluster" deliverable for task 1. Since Codespaces has no /dev/kvm, drop the KVM extraMounts from the earlier full script for now — we'll deal with that when we get to KubeVirt. Just create a plain cluster first:

Nandalily ➜ /workspaces/opi-assignment-2-2026/nankunda-lilian (main) $ cat <<EOF | kind create cluster --name ovs-lab --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF
Creating cluster "ovs-lab" ...
 ✓ Ensuring node image (kindest/node:v1.34.0) 🖼 
 ✓ Preparing nodes 📦  
 ✓ Writing configuration 📜 
 ✓ Starting control-plane 🕹️ 
 ✓ Installing CNI 🔌 
 ✓ Installing StorageClass 💾 
Set kubectl context to "kind-ovs-lab"
You can now use your cluster with:

kubectl cluster-info --context kind-ovs-lab

Have a nice day! 👋
@Nandalily ➜ /worksp


vandalily ➜ /workspaces/opi-assignment-2-2026/nankunda-lilian (main) $ kubectl get pods -A
NAMESPACE            NAME                                            READY   STATUS    RESTARTS   AGE
kube-system          coredns-66bc5c9577-gt2vz                        1/1     Running   0          2m39s
kube-system          coredns-66bc5c9577-nvwpf                        1/1     Running   0          2m39s
kube-system          etcd-ovs-lab-control-plane                      1/1     Running   0          2m48s
kube-system          kindnet-72gwb                                   1/1     Running   0          2m40s
kube-system          kube-apiserver-ovs-lab-control-plane            1/1     Running   0          2m48s
kube-system          kube-controller-manager-ovs-lab-control-plane   1/1     Running   0          2m48s
kube-system          kube-proxy-pdckm                                1/1     Running   0          2m40s
kube-system          kube-scheduler-ovs-lab-control-plane            1/1     Running   0          2m48s
local-path-storage   local-path-provisioner-7b8c8ddbd6-v66ww         1/1     Running   0          2m39s
@Nandalily ➜ /workspaces/opi-assignment-2-2026/nankunda-lilian (main) $ 


Task 1 summary for your assignment writeup: KinD cluster ovs-lab, single control-plane node, Kubernetes v1.34.0, default kindnet CNI, all system pods healthy.