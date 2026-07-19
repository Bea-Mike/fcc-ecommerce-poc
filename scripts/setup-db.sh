#!/bin/bash
# This script configures the PostgreSQL database via SSH inside the isolated network room.

set -e

if [ "$(whoami)" != "oneadmin" ]; then
    echo "Error: This script must be run as the 'oneadmin' user."
    exit 1
fi

if [ ! -f "../.db_env" ] && [ ! -f ".db_env" ]; then
    echo "Error: .db_env file not found! Please create it with DB_PASSWORD='...' in the project root."
    exit 1
fi
source ../.db_env 2>/dev/null || source .db_env

# FIX: Aligned variables with the true dynamic OpenNebula IPs
DB_IP="172.16.20.2"
K8S_MASTER_IP="172.16.100.2"
K8S_WORKER_IP="172.16.100.3"

echo "Testing SSH Connection to ${DB_IP}..."
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@${DB_IP} "echo '[Success] SSH connection established!'"

echo "Executing Database Setup..."

ssh -o StrictHostKeyChecking=no root@${DB_IP} "DB_PWD='${DB_PASSWORD}'" bash -s  << 'EOF'
    set -ex

    echo "Fixing DNS Resolution..."
    mkdir -p /etc/systemd/resolved.conf.d/
    echo "[Resolve]" > /etc/systemd/resolved.conf.d/dns.conf
    echo "DNS=8.8.8.8" >> /etc/systemd/resolved.conf.d/dns.conf
    systemctl restart systemd-resolved
    sleep 2
    
    ping -c 2 8.8.8.8 || { echo "Fatal: No internet routing. Exiting."; exit 1; }

    echo "Installing Packages..."
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib ufw

    echo "Configuring Network Binding..."
    PG_CONF=$(find /etc/postgresql -name postgresql.conf)
    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/g" "$PG_CONF"

    echo "Configuring Host-Based Auth..."
    PG_HBA=$(find /etc/postgresql -name pg_hba.conf)
    # Whitelisting the laptop host gateway alongside the corrected K8s IPs
    echo "host    all             all             172.16.100.2/32         md5" >> "$PG_HBA"
    echo "host    all             all             172.16.100.3/32         md5" >> "$PG_HBA"

    echo "Restarting Service..."
    systemctl restart postgresql
    systemctl enable postgresql

    echo "Provisioning Database and User..."
    sudo -u postgres psql -c "CREATE DATABASE ecommerce_db;" || true
    sudo -u postgres psql -c "CREATE USER db_user WITH PASSWORD '${DB_PWD}';" || true
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ecommerce_db TO db_user;" || true

    echo "Securing Firewall..."
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    
    # Whitelisting the laptop host gateway alongside the corrected K8s IPs
    ufw allow from 172.16.100.2 to any port 5432
    ufw allow from 172.16.100.3 to any port 5432
    ufw --force enable

    echo "[Success] Database configuration complete!"
EOF

echo "DB VM setup finished successfully!"