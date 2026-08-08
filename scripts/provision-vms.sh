#!/bin/bash
# This script provisions 3 VMs using OpenNebula.

set -e

VNET_NAME="vnet"
DB_VNET_NAME="db-net"
DATASTORE_NAME="default"

# Defined Fixed IP Topology
DB_IP="172.16.20.2"
K8S_MASTER_IP="172.16.100.2"
K8S_WORKER_IP="172.16.100.3"

echo "Configuring Flat Virtual Network DNS..."
# Append the DNS configuration directly to the default OpenNebula VNet
echo 'DNS="8.8.8.8 1.1.1.1"' > /tmp/vnet-dns.txt
chmod 644 /tmp/vnet-dns.txt
sudo -u oneadmin onevnet update "$VNET_NAME" /tmp/vnet-dns.txt --append
rm -f /tmp/vnet-dns.txt
echo "[Success] DNS injected into $VNET_NAME."

echo "Registering Isolated Database Network Room..."
if ! sudo -u oneadmin onevnet list 2>/dev/null | grep -q "$DB_VNET_NAME"; then
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
    chmod 644 /tmp/db-vnet-template.txt
    sudo -u oneadmin onevnet create /tmp/db-vnet-template.txt
    rm -f /tmp/db-vnet-template.txt
    echo "[Success] Network '$DB_VNET_NAME' successfully registered in OpenNebula."
else
    echo "[Info] OpenNebula network '$DB_VNET_NAME' already exists. Skipping registration."
fi

# Check if OS template already exists
echo "Checking OS Template Availability..."
if ! sudo -u oneadmin onetemplate list 2>/dev/null | grep -q "ubuntu-template"; then
    echo "Finding Ubuntu 22.04 in OpenNebula Marketplace..."
    
    # Resolve the exact App ID for Ubuntu 22.04 dynamically
    UBUNTU_APP_ID=$(sudo -u oneadmin onemarketapp list | grep -i "Ubuntu 22.04" | head -n 1 | awk '{print $1}')
    
    if [ -z "$UBUNTU_APP_ID" ]; then
        echo "Error: Could not locate Ubuntu 22.04 in OpenNebula Marketplace!"
        exit 1
    fi
    
    echo "Downloading Ubuntu 22.04 (Marketplace App ID: ${UBUNTU_APP_ID})..."
    sudo -u oneadmin onemarketapp export "${UBUNTU_APP_ID}" "ubuntu-template" -d "${DATASTORE_NAME}"
else
    echo "Template 'ubuntu-template' already exists. Skipping download..."
fi

# Helper function to wait until a VM reaches RUNNING state
wait_for_vm_running() {
    local vm_id=$1
    echo "Waiting for VM ID $vm_id to reach RUNNING state..."
    while true; do
        local lcm_state
        lcm_state=$(sudo -u oneadmin onevm show "$vm_id" | grep "LCM_STATE" | awk -F':' '{print $2}' | tr -d ' ')
        if [ "$lcm_state" = "RUNNING" ]; then
            echo "[Info] VM ID $vm_id is now RUNNING."
            break
        fi
        sleep 3
    done
}

# Function to provision VMs
provision_vm() {
    local vm_name=$1
    local memory=$2
    local cpu=$3
    local disk_size_mb=$4
    local target_nic=$5
    local target_ip=$6

    echo "Instantiating ${vm_name} at IP ${target_ip} (${memory}MB RAM, ${cpu} vCPU, ${disk_size_mb}MB Disk)..."

    # Instantiate VM using standard CLI flags
    local output
    output=$(sudo -u oneadmin onetemplate instantiate "ubuntu-template" \
        --name "$vm_name" \
        --memory "$memory" \
        --cpu "$cpu" \
        --vcpu "$cpu" \
        --nic "$target_nic:IP=$target_ip")

    # Extract the numeric VM ID
    local vm_id
    vm_id=$(echo "$output" | awk '{print $NF}')

    if [ -z "$vm_id" ]; then
        echo "Error: Failed to retrieve VM ID for $vm_name"
        exit 1
    fi

    wait_for_vm_running "$vm_id"

    local current_disk_size
    current_disk_size=$(sudo -u oneadmin onevm show "$vm_id" --xml | grep '<SIZE>' | head -n 1 | sed -E 's/.*<SIZE>(<!\[CDATA\[)?([0-9]+).*/\2/')

    if [ -n "$current_disk_size" ] && [ "$current_disk_size" -ge "$disk_size_mb" ] 2>/dev/null; then
        echo "[Info] DISK 0 for VM $vm_id ($vm_name) is already ${current_disk_size}MB. Skipping resize."
    else
        echo "Resizing DISK 0 for VM $vm_id ($vm_name) from ${current_disk_size:-unknown}MB to ${disk_size_mb}MB..."
        sudo -u oneadmin onevm disk-resize "$vm_id" 0 "$disk_size_mb"
    fi

    echo "[Success] $vm_name (ID: $vm_id) running with static IP: $target_ip!"
}

echo "Executing Micro-Segmented VM Provisioning..."
provision_vm "db-vm" 2048 1 10240 "$DB_VNET_NAME" "$DB_IP"
provision_vm "k8s-master" 3072 2 15360 "$VNET_NAME" "$K8S_MASTER_IP"
provision_vm "k8s-worker" 3072 2 15360 "$VNET_NAME" "$K8S_WORKER_IP"

echo "All VMs provisioned successfully!"
