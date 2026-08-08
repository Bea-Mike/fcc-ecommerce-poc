#!/bin/bash
# This script configures the PostgreSQL database via SSH inside the isolated network room.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DB_ENV_FILE="$PROJECT_ROOT/.db_env"

if [ ! -f "$DB_ENV_FILE" ]; then
    echo "Error: .db_env file not found at $DB_ENV_FILE!"
    exit 1
fi

source "$DB_ENV_FILE"

DB_USER="${DB_USER:-app_user}"
DB_NAME="${DB_NAME:-ecommerce_db}"

if [ -z "$DB_PASSWORD" ]; then
    echo "Error: DB_PASSWORD is not set in .db_env file!"
    exit 1
fi

DB_IP="172.16.20.2"

echo "Testing SSH Connection to ${DB_IP}..."
sudo -u oneadmin ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@${DB_IP} "echo '[Success] SSH connection established!'"

echo "Executing Database Setup and Schema Initialization..."

# Escape variables safely for shell expansion over SSH stdin (hides credentials from host ps aux)
SAFE_DB_PWD=$(printf '%q' "$DB_PASSWORD")
SAFE_DB_USER=$(printf '%q' "$DB_USER")
SAFE_DB_NAME=$(printf '%q' "$DB_NAME")

sudo -u oneadmin ssh -o StrictHostKeyChecking=no root@${DB_IP} bash -s << EOF
    set -ex

    DB_PWD=${SAFE_DB_PWD}
    DB_USER_VAR=${SAFE_DB_USER}
    DB_NAME_VAR=${SAFE_DB_NAME}

    echo "Fixing DNS Resolution..."
    if systemctl list-unit-files | grep -q systemd-resolved; then
        mkdir -p /etc/systemd/resolved.conf.d/
        echo "[Resolve]" > /etc/systemd/resolved.conf.d/dns.conf
        echo "DNS=8.8.8.8" >> /etc/systemd/resolved.conf.d/dns.conf
        systemctl restart systemd-resolved || true
    fi
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    sleep 2
    
    ping -c 2 8.8.8.8 || { echo "Fatal: No internet routing. Exiting."; exit 1; }

    echo "Installing Packages..."
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-contrib ufw

    echo "Configuring Network Binding..."
    PG_CONF=\$(find /etc/postgresql -name postgresql.conf)
    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/g" "\$PG_CONF"

    echo "Configuring Host-Based Auth..."
    PG_HBA=\$(find /etc/postgresql -name pg_hba.conf)
    # Whitelisting K8s IPs
    echo "host    all             all             172.16.100.2/32         md5" >> "\$PG_HBA"
    echo "host    all             all             172.16.100.3/32         md5" >> "\$PG_HBA"

    echo "Restarting Service..."
    systemctl restart postgresql
    systemctl enable postgresql

    echo "Provisioning Database and User..."
    sudo -u postgres psql -c "CREATE DATABASE \${DB_NAME_VAR};" || true
    sudo -u postgres psql -c "CREATE USER \${DB_USER_VAR} WITH PASSWORD '\${DB_PWD}';" || true
    sudo -u postgres psql -c "ALTER DATABASE \${DB_NAME_VAR} OWNER TO \${DB_USER_VAR};" || true

    echo "Initializing Schema and Everyday Seed Products..."
    sudo -u postgres psql -d "\${DB_NAME_VAR}" << SQL
    
-- Create Products Table
CREATE TABLE IF NOT EXISTS products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    price DECIMAL(10, 2) NOT NULL,
    stock INT NOT NULL
);

-- Create Orders Table
CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    product_id INT REFERENCES products(id),
    quantity INT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert Sample Everyday Products
INSERT INTO products (name, price, stock)
SELECT 'Classic Cotton T-Shirt', 19.99, 50
WHERE NOT EXISTS (SELECT 1 FROM products WHERE name = 'Classic Cotton T-Shirt');

INSERT INTO products (name, price, stock)
SELECT 'Stainless Steel Water Bottle', 14.50, 30
WHERE NOT EXISTS (SELECT 1 FROM products WHERE name = 'Stainless Steel Water Bottle');

INSERT INTO products (name, price, stock)
SELECT 'Premium Notebook & Pen Set', 12.00, 100
WHERE NOT EXISTS (SELECT 1 FROM products WHERE name = 'Premium Notebook & Pen Set');

-- Least-Privilege Model for Application User
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO \${DB_USER_VAR};
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \${DB_USER_VAR};

-- Ensure future tables/sequences follow the same restrictions
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE ON TABLES TO \${DB_USER_VAR};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO \${DB_USER_VAR};
SQL

    echo "Securing Firewall..."
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    
    # Whitelisting K8s nodes
    ufw allow from 172.16.100.2 to any port 5432
    ufw allow from 172.16.100.3 to any port 5432
    ufw --force enable

    echo "[Success] Database configuration complete!"
EOF

echo "DB VM setup finished successfully!"