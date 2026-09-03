#!/bin/bash
# This script generates synthetic traffic to test Horizontal Pod Autoscaling (HPA) via Ingress.

set -e

echo "Installing benchmarking tool (hey) if not present..."
if ! command -v hey &> /dev/null; then
    sudo apt-get install -y hey 2>/dev/null || snap install hey 2>/dev/null || true
fi

echo "Current HPA & Pod status before load test:"
kubectl get hpa,pods -l app=backend

echo "Dynamically resolving Kubernetes Ingress entrypoint..."
INGRESS_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo "Starting synthetic CPU load test against http://$INGRESS_IP/api/stress..."
echo "Sending 50 concurrent requests for 60 seconds..."

# Run 50 concurrent requests for 60 seconds targeting the CPU stress endpoint via Ingress
hey -z 60s -c 50 "http://$INGRESS_IP/api/stress?cycles=5000000" &

echo "Monitoring HPA scaling live for 90 seconds..."
watch -n 2 "kubectl get hpa,pods -l app=backend"