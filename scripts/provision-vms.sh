#!/bin/bash
# This script provisions 3 VMs (1 DB inside an isolated network, 2 K8s Nodes inside the flat network) using OpenNebula.

set -e

# Ensure the script is run as 'oneadmin'
if [ "$(whoami)" != "oneadmin" ]; then
    echo "Error: This script must be run as the 'oneadmin' user."
    exit 1
fi

VNET_NAME="vnet"
DB_VNET_NAME="db-net"
DATASTORE_NAME="default"

echo "Configuring Flat Virtual Network DNS..."
# Append the DNS configuration directly to the default OpenNebula VNet
echo 'DNS="8.8.8.8 1.1.1.1"' > /tmp/vnet-dns.txt
onevnet update "$VNET_NAME" /tmp/vnet-dns.txt --append
rm -f /tmp/vnet-dns.txt
echo "[Success] DNS injected into $VNET_NAME."

echo "Registering Isolated Database Network Room..."
# Register the VNet template only if it doesn't already exist
if ! onevnet list | grep -q "$DB_VNET_NAME"; then
    echo "Creating OpenNebula Virtual Network '$DB_VNET_NAME' linked to 'onebr-db'..."
    cat <<EOF > /tmp/db-vnet-template.txt
NAME = "$DB_VNET_NAME"
BRIDGE = "onebr-db"
VN_MAD = "bridge"
NETWORK_ADDRESS = "172.16.20.0"
NETWORK_MASK = "255.255.255.0"
GATEWAY = "172.16.20.1"
DNS = "8.8.8.8 1.1.1.1"
AR = [
    TYPE = "IP4",
    IP = "172.16.20.2",
    SIZE = "10"
]
EOF
    onevnet create /tmp/db-vnet-template.txt
    rm -f /tmp/db-vnet-template.txt
    echo "[Success] Network '$DB_VNET_NAME' successfully registered in OpenNebula."
else
    echo "[Info] OpenNebula network '$DB_VNET_NAME' already exists. Skipping registration."
fi

# Check if OS template already exists
echo "Checking OS Template Availability..."
if ! onetemplate list | grep -q "ubuntu-template"; then
    echo "Downloading Ubuntu 22.04 template from the OpenNebula Marketplace..."
    onemarketapp export 54 "ubuntu-template" -d ${DATASTORE_NAME}
else
    echo "Template 'ubuntu-template' already exists. Skipping download..."
fi

# Function to provision VMs flexibly across different networks
provision_vm() {
    local vm_name=$1
    local memory=$2
    local cpu=$3
    local target_nic=$4

    echo "Instantiating ${vm_name} (${memory}MB RAM, ${cpu} vCPU) on network '${target_nic}'..."
    
    onetemplate instantiate "ubuntu-template" \
        --name "$vm_name" \
        --memory "$memory" \
        --cpu "$cpu" --vcpu "$cpu" \
        --nic "$target_nic"
        
    echo "[Success] $vm_name was successfully submitted to the hypervisor!"
}

echo "Executing Micro-Segmented VM Provisioning..."
# Provision the Database VM inside the isolated network room
provision_vm "db-vm" 2048 1 "$DB_VNET_NAME"

# Provision the Kubernetes nodes inside the original flat network room
provision_vm "k8s-master" 3072 2 "$VNET_NAME"
provision_vm "k8s-worker" 3072 2 "$VNET_NAME"

echo "All VMs provisioned successfully!"
