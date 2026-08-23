#!/bin/bash

set -euo pipefail

# Enforce execution as root
if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: run.sh must be executed as root (e.g., 'sudo ./run.sh')."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "${SCRIPT_DIR}/scripts" ]]; then
    PROJECT_DIR="${SCRIPT_DIR}"
    SCRIPT_DIR="${PROJECT_DIR}/scripts"
else
    PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

DB_ENV_FILE="${PROJECT_DIR}/.db_env"
K8S_DIR="${PROJECT_DIR}/k8s"
SECRET_FILE="${K8S_DIR}/secret.yaml"
SECRET_TEMPLATE="${K8S_DIR}/secret.yaml.example"

echo "Checking required configuration files..."

# Check/create .db_env
if [[ ! -f "$DB_ENV_FILE" ]]; then
    echo ".db_env not found. Creating it..."
    read -r -p "Enter database username: " DB_USER
    read -r -s -p "Enter database password: " DB_PASSWORD
    echo
    if [[ -z "$DB_USER" || -z "$DB_PASSWORD" ]]; then
        echo "ERROR: DB_USER and DB_PASSWORD cannot be empty."
        exit 1
    fi
    cat > "$DB_ENV_FILE" <<EOF
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
EOF
    echo ".db_env created successfully."
else
    echo ".db_env already exists."
    if ! grep -q "^DB_USER=" "$DB_ENV_FILE"; then
        echo "ERROR: DB_USER missing in .db_env."
        exit 1
    fi
    if ! grep -q "^DB_PASSWORD=" "$DB_ENV_FILE"; then
        echo "ERROR: DB_PASSWORD missing in .db_env."
        exit 1
    fi
fi

chmod 644 "$DB_ENV_FILE"

# Check/create Kubernetes secret.yaml
mkdir -p "$K8S_DIR"
if [[ ! -f "$SECRET_FILE" ]]; then
    echo "secret.yaml not found."
    if [[ ! -f "$SECRET_TEMPLATE" ]]; then
        echo "ERROR: Missing secret template:"
        echo "$SECRET_TEMPLATE"
        exit 1
    fi
    echo "Loading credentials from .db_env..."
    source "$DB_ENV_FILE"
    DB_USER_B64=$(printf "%s" "$DB_USER" | base64)
    DB_PASSWORD_B64=$(printf "%s" "$DB_PASSWORD" | base64)
    echo "Creating secret.yaml from template..."
    cp "$SECRET_TEMPLATE" "$SECRET_FILE"
    sed -i "s|DB_USER:.*|DB_USER: \"${DB_USER_B64}\"|" "$SECRET_FILE"
    sed -i "s|DB_PASSWORD:.*|DB_PASSWORD: \"${DB_PASSWORD_B64}\"|" "$SECRET_FILE"
    chmod 644 "$SECRET_FILE"
    echo "secret.yaml created successfully."
else
    echo "secret.yaml already exists."
fi

echo "Setting script permissions..."
chmod +x \
    "$SCRIPT_DIR/bootstrap-host.sh" \
    "$SCRIPT_DIR/provision-vms.sh" \
    "$SCRIPT_DIR/setup-db.sh" \
    "$SCRIPT_DIR/setup-k8s.sh" \
    "$SCRIPT_DIR/teardown.sh" \
    "$SCRIPT_DIR/test-hpa.sh" 2>/dev/null || true

echo "Tearing down the infrastructure if present..."
"$SCRIPT_DIR/teardown.sh"

echo "Bootstrapping host..."
"$SCRIPT_DIR/bootstrap-host.sh"

echo "Provisioning OpenNebula VMs..."
"$SCRIPT_DIR/provision-vms.sh"

echo "Waiting for VM SSH connectivity..."
VM_IPS=(
    "172.16.100.2"
    "172.16.100.3"
    "172.16.20.2"
)
SSH_USER="root"
MAX_WAIT=300
WAIT_INTERVAL=10
ELAPSED=0
while true; do
    ALL_READY=true
    for IP in "${VM_IPS[@]}"; do
        echo "Checking SSH access to ${SSH_USER}@${IP}..."
        if sudo -u oneadmin ssh \
            -o ConnectTimeout=5 \
            -o StrictHostKeyChecking=no \
            -o BatchMode=yes \
            "${SSH_USER}@${IP}" "exit" 2>/dev/null; then
            echo "✓ ${IP} reachable"
        else
            echo "✗ ${IP} not ready"
            ALL_READY=false
        fi
    done
    if [[ "$ALL_READY" == true ]]; then
        echo "All VMs are reachable via SSH."
        break
    fi
    if [[ $ELAPSED -ge $MAX_WAIT ]]; then
        echo "ERROR: VMs did not become reachable within ${MAX_WAIT}s."
        exit 1
    fi
    echo "Retrying in ${WAIT_INTERVAL}s..."
    sleep "$WAIT_INTERVAL"
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

echo "Setting up database..."
"$SCRIPT_DIR/setup-db.sh"

echo "Setting up Kubernetes..."
"$SCRIPT_DIR/setup-k8s.sh"

# Dynamically fetch primary Host IP for Sunstone URL display
HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')

echo ""
echo "=================================================================="
echo "      🚀 E-COMMERCE POC DEPLOYMENT COMPLETED SUCCESSFULLY 🚀      "
echo "=================================================================="
echo ""
echo " You can now access the application and management interfaces:"
echo ""
echo "  🌐 Web Frontend Application : http://172.16.100.2/"
echo "  🔌 Backend Products API     : http://172.16.100.2/api/products"
echo "  ☁️ OpenNebula Sunstone UI   : http://${HOST_IP:-localhost}"
echo ""
echo " Useful Management Commands:"
echo "  - Test HPA / Autoscaling   : sudo ./scripts/test-hpa.sh"
echo ""
echo "=================================================================="