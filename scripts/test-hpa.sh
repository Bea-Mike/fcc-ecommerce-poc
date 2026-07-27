#!/bin/bash
# This script generates synthetic traffic to test Horizontal Pod Autoscaling (HPA).

set -e

echo "Installing benchmarking tool (hey) if not present..."
if ! command -v hey &> /dev/null; then
    sudo apt-get install -y hey 2>/dev/null || snap install hey 2>/dev/null || true
fi

echo "Current HPA & Pod status before load test:"
kubectl get hpa,pods -l app=backend

echo "Starting synthetic CPU load test against http://172.16.100.2/api/stress..."
echo "Sending 50 concurrent requests for 60 seconds..."

# Run 50 concurrent requests for 60 seconds targeting the CPU stress endpoint
hey -z 60s -c 50 http://172.16.100.2/api/stress?cycles=5000000 &

echo "Monitoring HPA scaling live for 90 seconds..."
watch -n 2 "kubectl get hpa,pods -l app=backend"