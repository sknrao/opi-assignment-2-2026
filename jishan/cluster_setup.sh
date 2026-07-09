#!/bin/bash
set -e

echo -e "OVS Datapath : Cluster Setup"

logstep(){
	echo -e "{STEP} $1"
}
loginfo(){
        echo -e "{INFO} $1"
}
logsuccess(){
        echo -e "{SUCCESS} $1"
}

CLUSTER_NAME="ovs-test-cluster"
#Creating the cluster with Kind
if kind get clusters 2>/dev/null | grep -q "$CLUSTER_NAME";then
  logsuccess "Cluster is present no need to create"
  kind export kubeconfig --name "$CLUSTER_NAME"
else
logstep "Creating KinD Cluster '$CLUSTER_NAME'"
	kind create cluster --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $CLUSTER_NAME
nodes:
  - role: control-plane
    image: kindest/node:v1.29.0
    extraMounts:
      - hostPath: /var/run/openvswitch
        containerPath: /var/run/openvswitch
        readOnly: false
      - hostPath: /etc/openvswitch
        containerPath: /etc/openvswitch
        readOnly: false
networking:
  apiServerAddress: "127.0.0.1"
  apiServerPort: 6443
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
  disableDefaultCNI: false
EOF
fi


loginfo "Waiting for cluster nodes to be ready"
kubectl wait --for=condition=Ready nodes --all --timeout=300s 2>/dev/null || true
kubectl get nodes


#Install KubeVirt

if kubectl get namespace kubevirt 2>/dev/null | grep kubevirt; then
	logsuccess "Kubevirt is present"
else
	logstep "Installing Kubeirt"
	kubectl create namespace kubevirt
	KUBEVIRT_VERSION="v1.8.2"
	kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml
        kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml
fi

loginfo "Waiting for KubeVirt components"
kubectl wait deployment virt-operator --for condition=available --timeout=300s -n kubevirt 2>/dev/null || true
kubectl wait deployment virt-api --for condition=available --timeout=300s -n kubevirt 2>/dev/null || true

#Error getted my virt-controller is crashing and getting into the CrashLoopBackOff error so I find these cmd form the internet 
#First providing the Grant permission for virt-controller
logstep "GRANT Permission"
kubectl create clusterrolebinding kubevirt-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=kubevirt:default 2>/dev/null || true

#Second the Crashing of the virt-conttroler
if kubectl get pods -n kubevirt -l kubevirt.io=virt-controller 2>/dev/null | grep -q "CrashLoopBackOff|Error"; then 
	loginfo "Restarting Kubevirt-controller"
	kubectl delete pods -n kubevirt -l kubevirt.io=virt-controller --grace-period=0 --force 2>/dev/null || true
	sleep 5
fi

kubectl wait deployment virt-controller --for condition=available --timeout=300s -n kubevirt 2>/dev/null || true

#Installing CDI 
if kubectl get namespace cdi 2>/dev/null | grep -q cdi; then
	logsuccess "CDI is present"
else
	logstep "Installing CDI"
	CDI_VERSION="v1.57.0"
	kubectl apply -f https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml
    kubectl apply -f https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml
fi 
loginfo "Waiting "
kubectl wait deployment cdi-operator --for condition=available --timeout=300s -n cdi 2>/dev/null || true


#Installing Multus
if kubectl get daemonset -n kube-system -l k8s-app=multus 2>/dev/null | grep -q multus; then
	logsuccess "Multus is Present"
else
	logstep "Installing Multus"
	kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml
	
fi
loginfo "Waiing for Multus"
kubectl wait pod --for=condition=Ready -l k8s-app=multus -n kube-system --timeout=300s 2>/dev/null || true

#Configre OVS
if ! command -v ovs-vsctl &> /dev/null; then 
	loginfo "Installing ovs"
	sudo apt-get install -y openvswitch-switch &>/dev/null
fi

if ! sudo systemctl is-active --quiet openvswitch-switch; then
	sudo systemctl start openvswitch-switch
fi
if ! sudo ovs-vsctl br-exists br-ovs;then
	sudo ovs-vsctl add-br br-ovs
fi

#For Istalling the CNI plugins and connect KinD bridge to OVS , here the problem was in the installation of the CNI , 
#like I have to use the  CLaude for that because here I have to create the dir , 
#executing the docker for the CLuster Plugin version and all because when 
#I completed the bash file and the with the manifest.yaml the VM was not creating after deep research 
#I found that I have to create the veth for this  and link it . That's why this part is of the troubleshooting ,
# where I faced that the VM is not running 
CNI_PLUGIN_VERSION="v1.3.0"
if ! docker exec "$CLUSTER_NAME-control-plane" ls /opt/cni/bin/bridge 2>/dev/null; then
    loginfo "Downloading CNI plugins"
    docker exec "$CLUSTER_NAME-control-plane" bash -c "
        curl -sL https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGIN_VERSION}.tgz | tar -C /opt/cni/bin -xz bridge host-local loopback portmap tuning
    " 2>/dev/null || {
        docker exec "$CLUSTER_NAME-control-plane" bash -c "
            mkdir -p /tmp/cni && cd /tmp/cni && \
            curl -sLO https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGIN_VERSION}.tgz && \
            tar -xzf cni-plugins-linux-amd64-${CNI_PLUGIN_VERSION}.tgz ./bridge && \
            mv bridge /opt/cni/bin/bridge && \
            chmod +x /opt/cni/bin/bridge && \
            rm -rf /tmp/cni
        " 2>/dev/null
    }
    logsuccess "bridge CNI plugin installed"
else
    logsuccess "bridge CNI plugin already present"
fi
logstep "Creating Linux bridge and connecting to OVS bridge"

if ! docker exec "$CLUSTER_NAME-control-plane" ip link show br-ovs 2>/dev/null; then
    loginfo "Creating Linux bridge br-ovs inside KinD node..."
    docker exec "$CLUSTER_NAME-control-plane" ip link add name br-ovs type bridge 2>/dev/null
    docker exec "$CLUSTER_NAME-control-plane" ip link set br-ovs up
    
    # Get the container's PID to set up veth pair from host side
    CONTAINER_PID=$(docker inspect "$CLUSTER_NAME-control-plane" --format '{{.State.Pid}}')
    loginfo "Container PID: $CONTAINER_PID"
    
    # Create veth pair: one end in host namespace, one in container namespace
    sudo ip link add veth-host type veth peer name veth-kind 2>/dev/null ||  true
    sudo ip link set veth-kind netns "$CONTAINER_PID" 2>/dev/null || true
    
    # Inside container: add veth-kind to br-ovs bridge and bring it up
    docker exec "$CLUSTER_NAME-control-plane" ip link set veth-kind up
    docker exec "$CLUSTER_NAME-control-plane" ip link set veth-kind master br-ovs
    
    # On host: add veth-host to OVS bridge br-ovs
    sudo ovs-vsctl add-port br-ovs veth-host 2>/dev/null || true
    sudo ip link set veth-host up
    
    logsuccess "Linux bridge br-ovs connected to OVS bridge br-ovs via veth pair"
else
    logsuccess "Linux bridge br-ovs already exists in KinD node"
fi

#Creating Namespace and NetworkAttachmentDefinition

if kubectl get namespace ovs-test 2>/dev/null | grep -q ovs-test;then
	logsuccess "Namespace Presennt"
else 
	kubectl create namespace ovs-test
fi

if kubectl get network-attachment-definitions -n ovs-test -o name  2>/dev/null | grep -q ovs-network; then
	logsuccess "Network Attachment dfinition present"
else
	logstep "Creating NAD"
	kubectl apply -f - <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ovs-network
  namespace: ovs-test
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "ovs-network",
      "type": "bridge",
      "bridge": "br-ovs",
      "isGateway": true,
      "ipMasq": true,
      "mtu": 1500,
      "ipam": {
        "type": "host-local",
        "subnet": "192.168.100.0/24",
        "rangeStart": "192.168.100.10",
        "rangeEnd": "192.168.100.50",
        "gateway": "192.168.100.1",
        "routes": [
          { "dst": "0.0.0.0/0" }
        ]
      }
    }
EOF
fi


#The Vriual machine is being deployed by the scrpit only 
MANIFESTS_DIR="$(dirname "$0")/../manifests"
if [ -f "$MANIFESTS_DIR/manifests.yaml" ]; then
    logstep "Deploying VM from manifests.yaml..."
    kubectl apply -f "$MANIFESTS_DIR/manifests.yaml" 2>/dev/null || true
    
    loginfo "Waiting for VM to be Running (this may take 1-2 minutes)..."
    for i in $(seq 1 30); do
        PHASE=$(kubectl get vmi -n ovs-test -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
        if [ "$PHASE" = "Running" ]; then
            logsuccess "VM is Running!"
            break
        fi
        sleep 10
    done
    
    VM_IP=$(kubectl get vmi -n ovs-test -o jsonpath='{.items[0].status.interfaces[1].ipAddress}' 2>/dev/null || echo "N/A")
    loginfo "VM OVS Network IP: $VM_IP"
else
    loginfo "manifests.yaml not found at $MANIFESTS_DIR, skipping VM deployment"
fi

#Verfiy and Display the status
echo ""
logsuccess "Kubernetes Nodes"
kubectl get nodes

echo ""
logsuccess "KubeVirt Pods"
kubectl get pods -n kubevirt -o wide

echo ""
logsuccess "CDI pods"
kubectl get pods -n cdi 2>/dev/null | head -5

echo ""
logsuccess "Multus:"
kubectl get pods -n kube-system 2>/dev/null | grep multus

echo ""
logsuccess "OVS Bridge Status:"
sudo ovs-vsctl show 2>/dev/null | grep -A 5 "Bridge"

echo ""
logsuccess "VM Status:"
kubectl get vmi -n ovs-test -o wide 2>/dev/null || echo "No VM deployed"

