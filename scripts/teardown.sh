#!/bin/bash
# This script safely destroys the PoC infrastructure.

# Ensure the script is run as 'oneadmin'
if [ "$(whoami)" != "oneadmin" ]; then
    echo "Error: This script must be run as the 'oneadmin' user."
    exit 1
fi

echo " Initiating Infrastructure Teardown..."
VMS_TO_DELETE=("db-vm" "k8s-master" "k8s-worker")

for VM_NAME in "${VMS_TO_DELETE[@]}"; do
    # Ask OpenNebula for the ID of the VM matching this name
    VM_ID=$(onevm list --list ID,NAME --no-header | grep -w "$VM_NAME" | awk '{print $1}')
    
    if [ -n "$VM_ID" ]; then
        echo "Terminating ${VM_NAME} (ID: ${VM_ID})..."
        onevm terminate --hard "$VM_ID"
    else
        echo "VM '${VM_NAME}' not found. Skipping."
    fi
done

echo "Waiting for virtual network interfaces to release..."
sleep 3

echo "Cleaning up isolated cloud networks..."
DB_VNET_NAME="db-net"

# Check if the isolated network exists, and delete it cleanly
if onevnet list --no-header | grep -q "$DB_VNET_NAME"; then
    echo "Deleting OpenNebula network '${DB_VNET_NAME}'..."
    onevnet delete "$DB_VNET_NAME"
    echo "[Success] Network '${DB_VNET_NAME}' completely removed."
else
    echo "Network '${DB_VNET_NAME}' not found or already deleted. Skipping."
fi

echo " Teardown Complete! The slate is clean."