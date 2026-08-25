#!/bin/bash
# This script safely destroys the PoC infrastructure, including networks, templates, and images.

set -e

echo "Initiating Infrastructure Teardown..."
VMS_TO_DELETE=("db-vm" "k8s-master" "k8s-worker")

for VM_NAME in "${VMS_TO_DELETE[@]}"; do
    VM_ID=$(sudo -u oneadmin onevm list --list ID,NAME --no-header 2>/dev/null | grep -w "$VM_NAME" | awk '{print $1}' || true)
    if [ -n "$VM_ID" ]; then
        echo "Terminating ${VM_NAME} (ID: ${VM_ID})..."
        sudo -u oneadmin onevm terminate --hard "$VM_ID"
    else
        echo "VM '${VM_NAME}' not found. Skipping."
    fi
done

echo "Waiting for virtual resources to release..."
sleep 3

echo "Cleaning up isolated cloud networks..."
DB_VNET_NAME="db-net"
K8S_VNET_NAME="k8s-net"

# 1. Rename k8s-net back to the default 'vnet'
if sudo -u oneadmin onevnet list --list NAME --no-header 2>/dev/null | grep -qw "$K8S_VNET_NAME"; then
    echo "Restoring Application Network name back to 'vnet'..."
    sudo -u oneadmin onevnet rename "$K8S_VNET_NAME" "vnet"
    echo "[Success] Network '$K8S_VNET_NAME' renamed back to 'vnet'."
else
    echo "Network '$K8S_VNET_NAME' not found or already renamed. Skipping."
fi

# Delete db-net completely
if sudo -u oneadmin onevnet list --no-header 2>/dev/null | grep -qw "$DB_VNET_NAME"; then
    echo "Deleting OpenNebula network '${DB_VNET_NAME}'..."
    sudo -u oneadmin onevnet delete "$DB_VNET_NAME"
    echo "[Success] Network '${DB_VNET_NAME}' completely removed."
else
    echo "Network '${DB_VNET_NAME}' not found or already deleted. Skipping."
fi

echo "Cleaning up OpenNebula templates and images..."
TEMPLATE_NAME="ubuntu-template"

# Remove template if present
if sudo -u oneadmin onetemplate list --no-header 2>/dev/null | grep -qw "$TEMPLATE_NAME"; then
    echo "Deleting OpenNebula template '${TEMPLATE_NAME}'..."
    sudo -u oneadmin onetemplate delete "$TEMPLATE_NAME"
    echo "[Success] Template '${TEMPLATE_NAME}' deleted."
else
    echo "Template '${TEMPLATE_NAME}' not found or already deleted. Skipping."
fi

# Remove backing image if present
if sudo -u oneadmin oneimage list --no-header 2>/dev/null | grep -qw "$TEMPLATE_NAME"; then
    echo "Deleting OpenNebula image '${TEMPLATE_NAME}'..."
    sudo -u oneadmin oneimage delete "$TEMPLATE_NAME"
    echo "[Success] Image '${TEMPLATE_NAME}' deleted."
else
    echo "Image '${TEMPLATE_NAME}' not found or already deleted. Skipping."
fi

echo "Teardown Complete! The slate is clean."