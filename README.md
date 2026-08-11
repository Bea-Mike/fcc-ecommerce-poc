# E-Commerce Cloud Infrastructure PoC

This repository contains a Proof of Concept (PoC) developed for the **Fog and Cloud Computing** course at the **University of Trento** by Beatrice Balzarini ([@beatricebalzarini](https://github.com/beatricebalzarini)) and Michael Bernasconi ([@Michael-Bernasconi](https://github.com/Michael-Bernasconi)).



## Project Overview

This PoC demonstrates an end-to-end, automated deployment of a multi-tier cloud application using Infrastructure-as-a-Service (IaaS) resource management and container orchestration. The objective is to provision, secure, and scale a full-stack e-commerce application from a single entrypoint script on a bare-metal host.

The pipeline automates host bootstrapping, OpenNebula MiniONE deployment, virtual machine provisioning, standalone database initialization, MicroK8s cluster formation, and application deployment.

### Key Technical Aspects

* **Infrastructure Automation:** A master shell script (`run.sh`) manages the entire setup and teardown lifecycle, building isolated bridges and virtual machines with zero manual GUI intervention.
* **Tier Isolation & Micro-segmentation:** The database is hosted on an isolated private VM network (`db-net`), shielded from public access and restricted to accept traffic solely from authorized Kubernetes node IPs via UFW and PostgreSQL host-based authentication (`pg_hba.conf`).
* **Kubernetes Orchestration:** Workloads run inside a two-node MicroK8s cluster (`k8s-master` and `k8s-worker`), utilizing NGINX Ingress Controller for routing, Metrics-Server for resource tracking, and Horizontal Pod Autoscaler (HPA) for automated workload scaling under load.
* **Container Hardening & In-Memory Secrets:** To prevent credential leaks in build logs or process inspects, application secrets (e.g., database credentials) are generated dynamically at startup and mounted into container pods as temporary in-memory (`tmpfs`) volume files at `/etc/secrets` rather than raw environment variables. Containers execute under restricted, non-root security contexts with all Linux capabilities dropped.


## Prerequisites & Constraints

* **Tested OS:** Ubuntu 24.04 LTS (Bare Metal).
* **Environment Warning:** Do **not** run this script inside a virtual machine (VirtualBox, VMware, WSL2, or unconfigured cloud VMs). The deployment installs KVM hypervisor tools directly on the host kernel; running inside an existing virtualized environment will cause hypervisor initialization failures.


## Architecture & Network Flow

```
                               +-------------------------------------------------+
                               |                 Bare-Metal Host                 |
                               |               (Ubuntu 24.04 LTS)                |
                               +-----------------------+-------------------------+
                                                       |
                                         +-------------+-------------+
                                         |                           |
                         +---------------+---------------+   +-------+-----------------------+
                         |     vnet (172.16.100.0/24)    |   |     db-net (172.16.20.0/24)   |
                         +---------------+---------------+   +-------+-----------------------+
                                         |                           |
                 +-----------------------+------------------+        |
                 |                                          |        |
      +----------v----------+                    +----------v--------v--+
      |     k8s-master      |                    |        k8s-worker      |
      |    172.16.100.2     |                    |       172.16.100.3     |
      | (MicroK8s Control)  |                    |    (MicroK8s Worker)   |
      +----------+----------+                    +--------------+-------+
                 |                                              |
                 +-----------------------+----------------------+
                                         | (SQL queries via 5432)
                                         v
                              +---------------------+
                              |        db-vm        |
                              |     172.16.20.2     |
                              | (PostgreSQL + UFW)  |
                              +---------------------+

```

### Component Breakdown & Network Connections

1. **Bare-Metal Host (Ubuntu 24.04):** Acts as the primary physical node running OpenNebula MiniONE. It creates two virtual bridges to separate application traffic from internal database traffic.
2. **`vnet` Subnet (`172.16.100.0/24`):** The primary network hosting the Kubernetes cluster (`k8s-master` and `k8s-worker`).
3. **`db-net` Subnet (`172.16.20.0/24`):** An isolated network tied to host bridge `onebr-db`. `db-vm` (`172.16.20.2`) resides exclusively on this private subnet.
4. **`k8s-master` (`172.16.100.2`) & `k8s-worker` (`172.16.100.3`):** The two virtual machines forming the MicroK8s cluster. Application microservices run inside pods scheduled across these nodes.
5. **How `k8s-worker` connects to `db-net`:**
   * Backend pods running inside the Kubernetes cluster query PostgreSQL at `172.16.20.2`.
   * When a backend pod sends a database query, traffic leaves the node (`172.16.100.3` or `172.16.100.2`) on `vnet` and is routed through the host kernel's IP forwarding table across the `onebr-db` bridge into `db-net`.
   * The host preserves the original source IP (`172.16.100.x`) without applying NAT.
   * `db-vm` receives the traffic on port 5432 and accepts it because its UFW firewall and PostgreSQL host authentication (`pg_hba.conf`) are explicitly configured to allow connections from `172.16.100.2` and `172.16.100.3`.


## Repository Structure

```
.
├── app/
│   ├── backend/                        # Node.js/Express API (PostgreSQL client, stress test route)
│   │   ├── .dockerignore               # Specifies files to exclude from the backend Docker build context
│   │   ├── Dockerfile                  # Container image build manifest for the Node.js backend environment
│   │   └── server.js                   # Express application entrypoint, database connection pool, health check, API endpoints
│   └── frontend/                       # Nginx-served static web interface
│       ├── .dockerignore               # Specifies files to exclude from the frontend Docker build context
│       ├── Dockerfile                  # Container image build manifest for the NGINX web server
│       └── index.html                  # Single-page HTML/JS user interface for the store
├── k8s/                                # Kubernetes Manifests
│   ├── backend-deployment.yaml         # Hardened deployment with in-memory secret volumes
│   ├── backend-hpa.yaml                # Horizontal Pod Autoscaler configuration
│   ├── backend-network-policy.yaml     # NetworkPolicy restricting ingress/egress for backend pods
│   ├── backend-service.yaml            # Internal ClusterIP service exposing backend API
│   ├── configmap.yaml                  # Non-sensitive database configs
│   ├── frontend-deployment.yaml        # Deployment manifest for web frontend pods
│   ├── frontend-network-policy.yaml    # NetworkPolicy isolating web frontend pods
│   ├── frontend-service.yaml           # Internal ClusterIP service exposing web frontend
│   ├── ingress.yaml                    # NGINX Ingress rules
│   ├── secret.yaml                     # Runtime generated (Git-ignored)
│   └── secret.yaml.example             # Base template for K8s secrets
├── scripts/
│   ├── bootstrap-host.sh               # KVM, Libvirt, OpenNebula MiniONE setup
│   ├── provision-vms.sh                # VM instantiation & disk sizing
│   ├── setup-db.sh                     # Remote PostgreSQL & UFW configuration
│   ├── setup-k8s.sh                    # Remote MicroK8s cluster formation & deployment
│   ├── teardown.sh                     # Clean resource removal
│   └── test-hpa.sh                     # Traffic generator for HPA stress testing
├── .db_env                             # Local credentials file (Git-ignored)
├── run.sh                              # Master orchestration entrypoint
└── README.md                           # Project documentation and setup guide
```


## How to Run

### 1. Clone the Repository

```bash
git clone https://github.com/Bea-Mike/fcc-ecommerce-poc
cd fcc-ecommerce-poc
```

### 2. Set Execution Permissions

```bash
chmod +x *.sh scripts/*.sh
```

### 3. Execute Deployment

```bash
sudo ./run.sh
```

If `.db_env` is missing, `run.sh` will prompt for a database username and password, store them locally, and auto-generate `k8s/secret.yaml` before orchestrating the build.


## Application Access & Operations

Once deployment finishes, access points are available at:

* **Web Frontend:** [`http://172.16.100.2/`](http://172.16.100.2/)
* **Backend API:** [`http://172.16.100.2/api/products`](http://172.16.100.2/api/products)
* **OpenNebula Sunstone:** `http://<HOST_IP>` (Default user: `oneadmin`)

### Stress Testing (HPA)

To simulate API load and test Horizontal Pod Autoscaling:

```bash
sudo ./scripts/test-hpa.sh
```

### Clean Teardown

To remove all created VMs, virtual networks, and cluster resources:

```bash
sudo ./scripts/teardown.sh
```