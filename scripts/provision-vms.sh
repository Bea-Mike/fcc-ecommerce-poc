#!/bin/bash
# This script provisions 3 VMs (1 DB, 2 K8s Nodes) using OpenNebula.

set -e

# Ensure the script is run as 'oneadmin'
if [ "$(whoami)" != "oneadmin" ]; then
    echo "Error: This script must be run as the 'oneadmin' user."
    exit 1
fi

VNET_NAME="vnet"
DATASTORE_NAME="default"

# Check if template already exists
if ! onetemplate list | grep -q "ubuntu-template"; then
    echo "Downloading Ubuntu 22.04 template from the OpenNebula Marketplace..."
    onemarketapp export 54 "ubuntu-template" -d ${DATASTORE_NAME}
else
    echo "Template 'ubuntu-template' already exists. Skipping download..."
fi

# Function to provision VMs
provision_vm() {
    local vm_name=$1
    local memory=$2
    local cpu=$3

    echo "Instantiating ${vm_name} (${memory}MB RAM, ${cpu} vCPU)..."
    
    onetemplate instantiate "ubuntu-template" \
        --name "$vm_name" \
        --memory "$memory" \
        --cpu "$cpu" --vcpu "$cpu" \
        --nic "$VNET_NAME"
        
    echo "[Success] $vm_name was successfully submitted to the hypervisor!"
}

# Execute the provisioning
provision_vm "db-vm" 2048 1
provision_vm "k8s-master" 3072 2
provision_vm "k8s-worker" 3072 2

echo "All VMs provisioned successfully!"
