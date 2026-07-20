#!/bin/bash
# This script installs MicroK8s and forms a cluster between the Master and Worker nodes.

set -e

if [ "$(whoami)" != "oneadmin" ]; then
    echo "Error: This script must be run as the 'oneadmin' user."
    exit 1
fi

K8S_MASTER_IP="172.16.100.2"
K8S_WORKER_IP="172.16.100.3"

echo "Pre-flight Checks..."
for IP in "$K8S_MASTER_IP" "$K8S_WORKER_IP"; do
    if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@"${IP}" "echo '[Success] SSH to ${IP} established!'"; then
        echo "Fatal: Cannot connect to node at ${IP}. Exiting."
        exit 1
    fi
done

# Function to install MicroK8s on a given node
install_microk8s() {
    local NODE_IP=$1
    local NODE_ROLE=$2
    
    echo "Installing MicroK8s on ${NODE_ROLE} (${NODE_IP})..."
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"${NODE_IP}" "NODE_ROLE='${NODE_ROLE}' bash -s" << 'EOF'
        set -ex

        echo "Configuring correct hostname for Kubernetes..."
        hostnamectl set-hostname "${NODE_ROLE}"
        echo "127.0.0.1 localhost" > /etc/hosts
        echo "127.0.1.1 ${NODE_ROLE}" >> /etc/hosts

        echo "Fixing DNS Resolution for Snap compatibility..."
        mkdir -p /etc/systemd/resolved.conf.d/
        echo "[Resolve]" > /etc/systemd/resolved.conf.d/dns.conf
        echo "DNS=8.8.8.8" >> /etc/systemd/resolved.conf.d/dns.conf
        systemctl restart systemd-resolved
        sleep 2
        
        ping -c 2 8.8.8.8 || { echo "Fatal: No internet routing. Exiting."; exit 1; }

        echo "Installing Snapd and MicroK8s..."
        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y snapd
        
        snap install microk8s --classic --channel=1.30/stable
        
        echo "Waiting for MicroK8s to initialize..."
        microk8s status --wait-ready
        
        snap alias microk8s.kubectl kubectl
        
        echo "[Success] MicroK8s installed on ${NODE_ROLE}!"
EOF
}

install_microk8s "$K8S_MASTER_IP" "k8s-master"
install_microk8s "$K8S_WORKER_IP" "k8s-worker"

echo "Enabling Master Add-ons (DNS)..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"${K8S_MASTER_IP}" "microk8s enable dns"

echo "Clustering the Nodes..."
IS_CLUSTERED=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"${K8S_MASTER_IP}" "microk8s.kubectl get nodes | grep -c 'k8s-worker' || true")

if [ "$IS_CLUSTERED" -eq 0 ]; then
    echo "Generating cluster join token on Master..."
    JOIN_CMD=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"${K8S_MASTER_IP}" "microk8s add-node | grep 'microk8s join' | head -n 1")
    
    if [ -z "$JOIN_CMD" ]; then
        echo "Fatal: Failed to generate a join token from the master."
        exit 1
    fi
    
    echo "Executing join command on Worker..."
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"${K8S_WORKER_IP}" "${JOIN_CMD}"
    
    echo "Waiting for Worker to register and become Ready..."
    WORKER_READY=false
    # Increased to 24 retries (120 seconds) to give the CNI network time to start
    for i in {1..24}; do
        STATUS=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"${K8S_MASTER_IP}" "microk8s.kubectl get nodes | grep 'k8s-worker' | awk '{print \$2}' || true")
        if [ "$STATUS" == "Ready" ]; then
            WORKER_READY=true
            break
        fi
        echo "Worker not ready yet. Retrying in 5 seconds..."
        sleep 5
    done
    
    if [ "$WORKER_READY" = false ]; then
         echo "Fatal: Worker node registered but failed to reach 'Ready' state."
         exit 1
    fi
else
    echo "[Info] Worker node is already joined to the cluster. Skipping clustering step."
fi

echo "Verifying Cluster Status..."
READY_NODES=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"${K8S_MASTER_IP}" "microk8s.kubectl get nodes | grep -c 'Ready' || true")

if [ "$READY_NODES" -ge 2 ]; then
    echo "[Success] Kubernetes infrastructure is fully provisioned, clustered, and READY!"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"${K8S_MASTER_IP}" "microk8s.kubectl get nodes -o wide"
else
    echo "Fatal: Expected at least 2 Ready nodes, but found ${READY_NODES}."
    exit 1
fi