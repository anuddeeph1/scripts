# Podman Container Logs Collection Guide
## For Nirmata-Managed Clusters

## Overview

In Nirmata-managed clusters, Kubernetes components run as **Podman containers** on each node. This guide shows how to collect logs from these containers.

## Container Components

Based on your cluster, these containers run on each node:

- **kube-apiserver** - Kubernetes API Server
- **kube-controller-manager** - Controller Manager
- **etcd** - etcd database
- **kube-scheduler** - Scheduler
- **kubelet** - Kubelet
- **kube-proxy** - Kube Proxy
- **nirmata-agent** - Nirmata Host Agent

## Quick Start

### Option 1: Collect from Single Node

```bash
# Run on the node
./collect-podman-logs.sh

# Or specify output directory
./collect-podman-logs.sh /tmp/my-logs

# Collect from all containers (not just Kubernetes)
./collect-podman-logs.sh /tmp/my-logs --all-containers
```

### Option 2: Collect from All Nodes

```bash
# 1. Create node list file (nodes.txt)
cat > nodes.txt <<EOF
GLCHBS-SS220643
GLCHBS-SS220644
10.165.174.225
EOF

# 2. Run collection script
./collect-all-nodes-logs.sh /path/to/kubeconfig nodes.txt

# 3. With custom SSH user/key
./collect-all-nodes-logs.sh /path/to/kubeconfig nodes.txt root /path/to/id_rsa
```

## Manual Log Collection

### View Container Logs

```bash
# List all containers
podman ps -a

# Get logs from specific container
podman logs apiserver --tail=1000
podman logs controller-manager --tail=1000
podman logs etcd --tail=1000

# Follow logs
podman logs -f apiserver

# Get logs with timestamps
podman logs apiserver --timestamps --tail=1000
```

### Save Logs to File

```bash
# Save full logs
podman logs apiserver > apiserver.log

# Save errors only
podman logs apiserver 2>&1 | grep -i "error\|failed\|503" > apiserver-errors.log

# Save last 10000 lines
podman logs apiserver --tail=10000 > apiserver.log
```

## What Logs to Review

### Priority 1: API Server Logs

```bash
# Get API server logs
podman logs apiserver --tail=5000 > apiserver.log

# Check for APIService errors
podman logs apiserver --tail=5000 | grep -i "apiservice\|503\|service unavailable"

# Check for timeout errors
podman logs apiserver --tail=5000 | grep -i "timeout\|deadline"

# Check for etcd errors
podman logs apiserver --tail=5000 | grep -i "etcd"
```

**What to look for:**
- `503 Service Unavailable` - APIService errors
- `timeout` - Performance issues
- `etcd` errors - etcd connection problems

### Priority 2: Controller Manager Logs

```bash
# Get controller manager logs
podman logs controller-manager --tail=5000 > controller-manager.log

# Check for namespace errors
podman logs controller-manager --tail=5000 | grep -i "namespace"

# Check for finalizer errors
podman logs controller-manager --tail=5000 | grep -i "finalizer"

# Check for deletion errors
podman logs controller-manager --tail=5000 | grep -i "delete\|cleanup"
```

**What to look for:**
- `error syncing namespace` - Namespace controller issues
- `failed to delete namespace` - Deletion failures
- `finalizer` errors - Finalizer removal failures

### Priority 3: etcd Logs

```bash
# Get etcd logs
podman logs etcd --tail=5000 > etcd.log

# Check for performance issues
podman logs etcd --tail=5000 | grep -i "slow\|timeout"

# Check for connection issues
podman logs etcd --tail=5000 | grep -i "connection"
```

**What to look for:**
- `slow request` - Performance degradation
- `timeout` - etcd not responding
- `connection` errors - Network issues

### Priority 4: Container Runtime Logs

```bash
# Check podman service logs
journalctl -u podman -n 1000 | grep -i "error\|failed"

# Check containerd logs (if exists)
journalctl -u containerd -n 1000 | grep -i "error\|failed\|timeout"
```

## Container Status Check

```bash
# Check all containers
podman ps -a

# Check container health
podman inspect apiserver | jq '.[0].State'

# Check container resource usage
podman stats --no-stream

# Check container logs size
podman logs apiserver 2>&1 | wc -l
```

## Common Issues and Logs

### Issue 1: APIService Unavailable

**Container:** `apiserver`

**Log Pattern:**
```
"HTTP" resp=503 statusStack=... "service unavailable"
```

**Check:**
```bash
podman logs apiserver | grep -i "503\|service unavailable\|apiservice"
```

### Issue 2: Namespace Controller Errors

**Container:** `controller-manager`

**Log Pattern:**
```
"error syncing namespace"
"failed to delete namespace"
```

**Check:**
```bash
podman logs controller-manager | grep -i "namespace\|delete"
```

### Issue 3: etcd Performance

**Container:** `etcd`

**Log Pattern:**
```
"slow request"
"took too long"
```

**Check:**
```bash
podman logs etcd | grep -i "slow\|timeout"
```

## Scripts Created

### 1. `collect-podman-logs.sh`
- Collects logs from all Kubernetes component containers
- Extracts error logs
- Collects system information
- Run on each node

**Usage:**
```bash
./collect-podman-logs.sh [output-dir] [--all-containers]
```

### 2. `collect-all-nodes-logs.sh`
- Collects logs from all nodes via SSH
- Collects cluster-level information
- Organizes logs by node
- Run from central location

**Usage:**
```bash
./collect-all-nodes-logs.sh <kubeconfig> <node-list-file> [ssh-user] [ssh-key]
```

## Complete Workflow

### Step 1: Collect Logs from All Nodes

```bash
# Create node list
cat > nodes.txt <<EOF
GLCHBS-SS220643
GLCHBS-SS220644
EOF

# Collect from all nodes
./collect-all-nodes-logs.sh /path/to/kubeconfig nodes.txt
```

### Step 2: Review Collected Logs

```bash
# Check broken APIServices
cat cluster-logs-all-nodes-*/cluster-info/unavailable-apiservices.txt

# Check API server errors from first node
cat cluster-logs-all-nodes-*/GLCHBS-SS220643/kube-apiserver-errors.log

# Check controller manager errors
cat cluster-logs-all-nodes-*/GLCHBS-SS220643/kube-controller-manager-errors.log

# Check etcd errors
cat cluster-logs-all-nodes-*/GLCHBS-SS220643/etcd-errors.log
```

### Step 3: Compare Across Nodes

```bash
# Compare API server errors across nodes
for node in cluster-logs-all-nodes-*/; do
    echo "=== $node ==="
    grep -i "apiservice\|503" "$node"/*/kube-apiserver-errors.log | head -5
done
```

## Manual Collection (If Scripts Not Available)

### On Each Node:

```bash
# Create output directory
mkdir -p /tmp/podman-logs
cd /tmp/podman-logs

# Collect logs from each container
podman logs apiserver --tail=10000 > kube-apiserver.log
podman logs controller-manager --tail=10000 > kube-controller-manager.log
podman logs etcd --tail=10000 > etcd.log
podman logs scheduler --tail=10000 > kube-scheduler.log
podman logs kubelet --tail=10000 > kubelet.log
podman logs proxy --tail=10000 > kube-proxy.log
podman logs nirmata-agent --tail=10000 > nirmata-agent.log

# Extract errors
podman logs apiserver --tail=10000 2>&1 | grep -i "error\|failed\|503" > kube-apiserver-errors.log
podman logs controller-manager --tail=10000 2>&1 | grep -i "error\|failed" > kube-controller-manager-errors.log
podman logs etcd --tail=10000 2>&1 | grep -i "error\|failed\|slow" > etcd-errors.log

# System information
podman ps -a > containers-status.txt
df -h > disk-usage.txt
free -h > memory-info.txt

# System logs
journalctl -u podman -n 1000 > system-podman.log 2>&1
journalctl -u containerd -n 1000 > system-containerd.log 2>&1

# Compress
tar -czf podman-logs-$(hostname)-$(date +%Y%m%d).tar.gz *
```

## Troubleshooting

### Cannot Connect via SSH

```bash
# Test SSH connection
ssh root@GLCHBS-SS220643 "echo 'Connection test'"

# Check SSH key
ssh -i /path/to/id_rsa root@GLCHBS-SS220643 "echo 'Connection test'"
```

### Container Not Found

```bash
# List all containers
podman ps -a

# Check container name
podman ps -a | grep apiserver

# Use container ID instead
podman logs <container-id>
```

### Logs Too Large

```bash
# Get only recent logs
podman logs apiserver --tail=1000

# Get logs since specific time
podman logs apiserver --since 1h

# Get logs with timestamps and filter
podman logs apiserver --timestamps --since 1h | grep -i "error"
```

## Summary

**For Nirmata-managed clusters with Podman containers:**

1. **Single Node:** Run `./collect-podman-logs.sh` on the node
2. **All Nodes:** Run `./collect-all-nodes-logs.sh` with node list
3. **Manual:** Use `podman logs <container-name>` for individual containers
4. **Review:** Check error logs for APIService, namespace, and etcd issues

**Key containers to check:**
- `apiserver` - API server errors
- `controller-manager` - Namespace controller errors
- `etcd` - Performance issues
