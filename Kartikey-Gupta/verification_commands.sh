#!/bin/bash
# Commands to verify OVS datapath and VM connectivity

echo "=== Verification Commands for OVS and KubeVirt Setup ==="
echo ""

echo "1. Wait for VM to be ready:"
echo "kubectl wait --for=condition=Ready vmi/vm-cirros -n default --timeout=300s"
echo ""

echo "2. Get VM IP addresses:"
echo "kubectl get vmi vm-cirros -n default -o jsonpath='{.status.interfaces}' | jq"
echo ""

echo "3. Access VM console (in separate terminal):"
echo "virtctl console vm-cirros"
echo "# Login with: cirros / gocubsgo"
echo ""

echo "4. From within VM console, test connectivity:"
echo "# Get interface info"
echo "ip addr"
echo "# Ping gateway or another VM"
echo "ping -c 4 10.244.0.1"
echo ""

echo "5. Capture ping results from VM console to file:"
echo "virtctl console vm-cirros --timeout=30s <<EOF > ping_results.txt"
echo "cirros"
echo "gocubsgo"
echo "ping -c 4 10.244.0.1"
echo "exit"
echo "EOF"
echo ""

echo "6. Alternative: SSH into VM if network is working:"
echo "VM_IP=\$(kubectl get vmi vm-cirros -o jsonpath='{.status.interfaces[0].ipAddress}')"
echo "ssh cirros@\$VM_IP 'ping -c 4 10.244.0.1' > ping_results.txt"
echo ""

echo "7. Dump OVS flows in JSON format:"
echo "sudo ovs-ofctl dump-flows ovs-br0 --format=json > verification_flows.json"
echo ""

echo "8. Alternative: SSH into k3s node and dump flows:"
echo "kubectl get nodes -o wide  # Get node name"
echo "ssh <node-name> 'sudo ovs-ofctl dump-flows ovs-br0 --format=json' > verification_flows.json"
echo ""

echo "9. For local macOS/k3s setup:"
echo "sudo ovs-ofctl dump-flows ovs-br0 -O OpenFlow13 > flows.txt"
echo "# Then convert to JSON or use the mock data below"
echo ""

echo "=== If local environment fails, use the mock data below ==="
