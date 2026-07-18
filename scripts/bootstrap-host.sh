#!/bin/bash
# This script prepares a fresh Ubuntu 22.04/24.04 machine to host the IaaS environment.
# It installs KVM dependencies, SSH, and deploys MiniONE.

echo "Installing KVM, Hypervisor dependencies, and SSH..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils curl openssh-server

echo "Ensuring SSH service is running..."
sudo systemctl enable --now ssh

echo "Downloading and executing MiniONE..."
wget -qO minione https://github.com/OpenNebula/minione/releases/latest/download/minione
chmod +x minione
sudo ./minione --yes

echo "Host is ready. Please save the oneadmin password printed above!"