#!/bin/bash
# This script prepares a fresh Ubuntu 22.04/24.04 machine to host the IaaS environment.
# It installs KVM dependencies, SSH, and deploys MiniONE.

set -e

# Skip everything if OpenNebula is already installed
if id "oneadmin" &>/dev/null && command -v onehost &>/dev/null; then
    echo "[Info] OpenNebula (MiniONE) is already installed on this host."
    echo "Skipping bootstrap to avoid overwriting your active environment."
    exit 0
fi

echo "Installing KVM, Hypervisor dependencies, and SSH..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils curl openssh-server

echo "Ensuring SSH service is running..."
sudo systemctl enable --now ssh

echo "Downloading and executing MiniONE..."
wget -qO /tmp/minione https://github.com/OpenNebula/minione/releases/latest/download/minione
chmod +x /tmp/minione

echo "Running MiniONE deployment..."
sudo /tmp/minione --yes

rm -f /tmp/minione

echo "[Success] Host bootstrap completed!"
echo "Please save the 'oneadmin' password printed above if this was a fresh install."