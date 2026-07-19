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

echo " Teardown Complete! The slate is clean."