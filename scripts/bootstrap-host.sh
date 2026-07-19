#!/bin/bash
# This script prepares a fresh Ubuntu 22.04/24.04 machine to host the IaaS environment.
# It installs KVM dependencies, SSH, deploys MiniONE, and configures isolated network routing.

set -e

echo "Installing KVM, Hypervisor dependencies, and SSH..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils curl openssh-server

echo "Ensuring SSH service is running..."
sudo systemctl enable --now ssh

echo "Checking MiniONE Deployment Status..."
if id "oneadmin" &>/dev/null && command -v onehost &>/dev/null; then
    echo "[Info] OpenNebula (MiniONE) is already installed on this host. Skipping deployment."
else
    echo "Downloading and executing MiniONE..."
    wget -qO /tmp/minione https://github.com/OpenNebula/minione/releases/latest/download/minione
    chmod +x /tmp/minione

    echo "Running MiniONE deployment..."
    sudo /tmp/minione --yes
    rm -f /tmp/minione
    echo "[Success] MiniONE core installation completed!"
fi

echo "Configuring Isolated Database Network Bridge..."
# Only create the bridge if it doesn't already exist
if ! ip link show dev onebr-db &>/dev/null; then
    echo "Creating virtual bridge 'onebr-db'..."
    sudo ip link add name onebr-db type bridge
    sudo ip addr add 172.16.20.1/24 dev onebr-db
    sudo ip link set dev onebr-db up
    echo "[Success] Bridge 'onebr-db' initialized at 172.16.20.1"
else
    echo "[Info] Virtual bridge 'onebr-db' already exists. Skipping creation."
fi

echo "Enforcing Linux Kernel IP Forwarding..."
# Enable routing dynamically
sudo sysctl -w net.ipv4.ip_forward=1
# Make routing persistent across system reboots
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-cloud-routing.conf > /dev/null

echo "Configuring Conditional NAT Firewall Rules..."
# Only add the conditional NAT rule if it doesn't already exist in the iptables chain
if ! sudo iptables -t nat -C POSTROUTING -s 172.16.20.0/24 ! -d 172.16.0.0/12 -j MASQUERADE &>/dev/null; then
    echo "Applying conditional internet masquerading for the database zone..."
    sudo iptables -t nat -A POSTROUTING -s 172.16.20.0/24 ! -d 172.16.0.0/12 -j MASQUERADE
else
    echo "[Info] Conditional NAT rule already present."
fi

echo "[Success] Host bootstrap and isolated network architecture completed!"