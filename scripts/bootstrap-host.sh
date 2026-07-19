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
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-cloud-routing.conf > /dev/null

echo "Configuring Conditional NAT Firewall Rules..."
if ! sudo iptables -t nat -C POSTROUTING -s 172.16.20.0/24 ! -d 172.16.0.0/12 -j MASQUERADE &>/dev/null; then
    echo "Applying conditional internet masquerading for the database zone..."
    sudo iptables -t nat -A POSTROUTING -s 172.16.20.0/24 ! -d 172.16.0.0/12 -j MASQUERADE
else
    echo "[Info] Conditional NAT rule already present."
fi

echo "Preventing MiniONE from hiding K8s node identities..."
# Clean old instances to keep the rules clean and idempotent
sudo iptables -t nat -D POSTROUTING -s 172.16.100.0/24 -d 172.16.20.0/24 -j RETURN 2>/dev/null || true
sudo iptables -t nat -D POSTROUTING -s 172.16.20.0/24 -d 172.16.100.0/24 -j RETURN 2>/dev/null || true
sudo iptables -D FORWARD -s 172.16.100.0/24 -d 172.16.20.0/24 -j ACCEPT 2>/dev/null || true
sudo iptables -D FORWARD -s 172.16.20.0/24 -d 172.16.100.0/24 -j ACCEPT 2>/dev/null || true

# Force the host router to preserve the real IPs for internal cross-subnet traffic
sudo iptables -t nat -I POSTROUTING 1 -s 172.16.100.0/24 -d 172.16.20.0/24 -j RETURN
sudo iptables -t nat -I POSTROUTING 1 -s 172.16.20.0/24 -d 172.16.100.0/24 -j RETURN
sudo iptables -I FORWARD 1 -s 172.16.100.0/24 -d 172.16.20.0/24 -j ACCEPT
sudo iptables -I FORWARD 1 -s 172.16.20.0/24 -d 172.16.100.0/24 -j ACCEPT

echo "[Success] Host bootstrap and isolated network architecture completed!"