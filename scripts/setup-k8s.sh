#!/bin/bash
# This script installs MicroK8s, forms a cluster, and deploys all k8s manifests remotely via kubeconfig.

set -e

# Prevent running as oneadmin or root directly to keep local permissions intact
if [ "$(whoami)" == "oneadmin" ] || [ "$(whoami)" == "root" ]; then
    echo "Error: Please run this script as your normal host user."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
K8S_MANIFEST_DIR="$PROJECT_ROOT/k8s"

K8S_MASTER_IP="172.16.100.2"
K8S_WORKER_IP="172.16.100.3"

# Pre-flight Checks (Local Files)
if [ ! -d "$K8S_MANIFEST_DIR" ]; then
    echo "Fatal: Kubernetes manifest directory not found at ${K8S_MANIFEST_DIR}."
    exit 1
fi

if [ ! -f "$K8S_MANIFEST_DIR/secret.yaml" ]; then
    echo "Fatal: $K8S_MANIFEST_DIR/secret.yaml is missing. Please create it from secret.yaml.example."
    exit 1
fi

echo "Pre-flight SSH Checks..."
for IP in "$K8S_MASTER_IP" "$K8S_WORKER_IP"; do
    if ! sudo -u oneadmin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 root@"${IP}" "echo '[Success] SSH to ${IP} established!'"; then
        echo "Fatal: Cannot connect to node at ${IP}. Exiting."
        exit 1
    fi
done

# Function to install MicroK8s on a given node
install_microk8s() {
    local NODE_IP=$1
    local NODE_ROLE=$2
    
    echo "Installing MicroK8s on ${NODE_ROLE} (${NODE_IP})..."
    sudo -u oneadmin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"${NODE_IP}" "NODE_ROLE='${NODE_ROLE}' bash -s" << 'EOF'
        set -ex

        echo "Configuring correct hostname for Kubernetes..."
        hostnamectl set-hostname "${NODE_ROLE}"
        echo "127.0.0.1 localhost" > /etc/hosts
        echo "127.0.1.1 ${NODE_ROLE}" >> /etc/hosts
        echo "172.16.100.2 k8s-master" >> /etc/hosts
        echo "172.16.100.3 k8s-worker" >> /etc/hosts

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

echo "Enabling Master Add-ons (DNS, Metrics-Server, Ingress)..."
sudo -u oneadmin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"${K8S_MASTER_IP}" "microk8s enable dns metrics-server ingress"

echo "Clustering the Nodes..."
IS_CLUSTERED=$(sudo -u oneadmin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"${K8S_MASTER_IP}" "microk8s.kubectl get nodes | grep -c 'k8s-worker' || true")

if [ "$IS_CLUSTERED" -eq 0 ]; then
    echo "Generating cluster join token on Master..."
    JOIN_CMD=$(sudo -u oneadmin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"${K8S_MASTER_IP}" "microk8s add-node --format short")
    
    if [ -z "$JOIN_CMD" ]; then
        echo "Fatal: Failed to generate a join token from the master."
        exit 1
    fi
    
    echo "Executing join command on Worker..."
    sudo -u oneadmin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"${K8S_WORKER_IP}" "${JOIN_CMD}"
    
    echo "Waiting for Worker to register and become Ready..."
    WORKER_READY=false
    # Increased to 24 retries (120 seconds) to give the CNI network time to start
    for i in {1..24}; do
        STATUS=$(sudo -u oneadmin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"${K8S_MASTER_IP}" "microk8s.kubectl get nodes | grep 'k8s-worker' | awk '{print \$2}' || true")
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

echo "Configuring Remote Kubeconfig for Local Control..."
mkdir -p ~/.kube
sudo -u oneadmin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"${K8S_MASTER_IP}" "microk8s config" > ~/.kube/config
chmod 600 ~/.kube/config

# Verify local kubectl can communicate with the remote cluster API
if ! kubectl cluster-info &>/dev/null; then
    echo "Fatal: Failed to communicate with the Kubernetes API server using remote kubeconfig."
    exit 1
fi

echo "Deploying Application Manifests Remotely in Dependency Order..."
set -x

echo "Waiting for Ingress Controller & System Add-ons to be ready..."
kubectl rollout status daemonset/nginx-ingress-microk8s-controller -n ingress --timeout=120s
kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s

echo "Applying ConfigMaps and Secrets..."
kubectl apply -f "$K8S_MANIFEST_DIR/configmap.yaml"
kubectl apply -f "$K8S_MANIFEST_DIR/secret.yaml"

echo "Applying Kubernetes Services..."
kubectl apply -f "$K8S_MANIFEST_DIR/backend-service.yaml"
kubectl apply -f "$K8S_MANIFEST_DIR/frontend-service.yaml"

echo "Applying Microservice Deployments..."
kubectl apply -f "$K8S_MANIFEST_DIR/backend-deployment.yaml"
kubectl apply -f "$K8S_MANIFEST_DIR/frontend-deployment.yaml"

echo "Waiting for Application Rollouts..."
kubectl rollout status deployment/backend-deployment --timeout=180s
kubectl rollout status deployment/frontend-deployment --timeout=180s

echo "Applying Network Policies..."
kubectl apply -f "$K8S_MANIFEST_DIR/backend-network-policy.yaml"
kubectl apply -f "$K8S_MANIFEST_DIR/frontend-network-policy.yaml"

echo "Applying Autoscaling (HPA) and Ingress..."
kubectl apply -f "$K8S_MANIFEST_DIR/backend-hpa.yaml"
kubectl apply -f "$K8S_MANIFEST_DIR/ingress.yaml"

set +x

echo "Performing Final End-to-End Validation..."
HEALTH_CHECK_PASSED=false
for i in {1..12}; do
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://172.16.100.2/api/products || true)
    if [ "$HTTP_CODE" == "200" ]; then
        HEALTH_CHECK_PASSED=true
        break
    fi
    echo "Waiting for API endpoint (http://172.16.100.2/api/products) to respond HTTP 200 (Got: ${HTTP_CODE}). Retrying in 5 seconds..."
    sleep 5
done

if [ "$HEALTH_CHECK_PASSED" = true ]; then
    echo "[SUCCESS] The entire Kubernetes infrastructure and application stack is fully provisioned, secured remotely, and responsive!"
    kubectl get pods,svc,ingress,hpa -o wide
else
    echo "Fatal: Application deployed, but health check failed at http://172.16.100.2/api/products."
    exit 1
fi