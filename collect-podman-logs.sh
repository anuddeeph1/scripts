#!/bin/bash

# Podman Container Log Collection Script
# For Nirmata-managed clusters where Kubernetes components run as Podman containers
# Run this script on each node to collect logs

if [ $# -lt 1 ]; then
    echo "Usage: $0 [output-dir] [--all-containers]"
    echo ""
    echo "* output-dir: (Optional) Directory to save logs. Default: ./podman-logs-<hostname>-<timestamp>"
    echo "* --all-containers: (Optional) Collect logs from all containers, not just Kubernetes components"
    echo ""
    echo "Eg: $0"
    echo "Eg: $0 /tmp/logs"
    echo "Eg: $0 /tmp/logs --all-containers"
    exit 1
fi

output_dir=${1:-"./podman-logs-$(hostname)-$(date +%Y%m%d-%H%M%S)"}
collect_all=${2:-""}

mkdir -p "$output_dir"

echo "=========================================="
echo "Podman Container Log Collection"
echo "=========================================="
echo "Hostname: $(hostname)"
echo "Output directory: $output_dir"
echo ""

# Function to collect container logs
collect_container_logs() {
    local container_name=$1
    local container_id=$2
    local description=$3
    
    if [ -z "$container_id" ]; then
        echo "  ⚠ Container '$container_name' not found"
        return 1
    fi
    
    echo "Collecting logs from: $container_name ($container_id)"
    
    # Get full logs
    podman logs "$container_id" --tail=10000 > "$output_dir/${container_name}.log" 2>&1
    
    # Extract errors only
    podman logs "$container_id" --tail=10000 2>&1 | \
        grep -i "error\|failed\|timeout\|503\|500\|panic\|fatal" > "$output_dir/${container_name}-errors.log" 2>&1
    
    # Get container info
    podman inspect "$container_id" > "$output_dir/${container_name}-inspect.json" 2>&1
    
    echo "  ✓ Collected logs and errors"
}

# Get container IDs
echo "Identifying Kubernetes component containers..."
echo ""

# API Server
api_id=$(podman ps -a --filter "name=apiserver" --format "{{.ID}}" | head -1)
if [ -n "$api_id" ]; then
    collect_container_logs "kube-apiserver" "$api_id" "Kubernetes API Server"
else
    echo "  ⚠ kube-apiserver container not found"
fi

# Controller Manager
cm_id=$(podman ps -a --filter "name=controller-manager" --format "{{.ID}}" | head -1)
if [ -n "$cm_id" ]; then
    collect_container_logs "kube-controller-manager" "$cm_id" "Kubernetes Controller Manager"
else
    echo "  ⚠ kube-controller-manager container not found"
fi

# etcd
etcd_id=$(podman ps -a --filter "name=etcd" --format "{{.ID}}" | head -1)
if [ -n "$etcd_id" ]; then
    collect_container_logs "etcd" "$etcd_id" "etcd"
else
    echo "  ⚠ etcd container not found"
fi

# Scheduler
scheduler_id=$(podman ps -a --filter "name=scheduler" --format "{{.ID}}" | head -1)
if [ -n "$scheduler_id" ]; then
    collect_container_logs "kube-scheduler" "$scheduler_id" "Kubernetes Scheduler"
else
    echo "  ⚠ kube-scheduler container not found"
fi

# Kubelet
kubelet_id=$(podman ps -a --filter "name=kubelet" --format "{{.ID}}" | head -1)
if [ -n "$kubelet_id" ]; then
    collect_container_logs "kubelet" "$kubelet_id" "Kubelet"
else
    echo "  ⚠ kubelet container not found"
fi

# Kube-proxy
proxy_id=$(podman ps -a --filter "name=proxy" --format "{{.ID}}" | head -1)
if [ -n "$proxy_id" ]; then
    collect_container_logs "kube-proxy" "$proxy_id" "Kube Proxy"
else
    echo "  ⚠ kube-proxy container not found"
fi

# Nirmata Agent
nirmata_id=$(podman ps -a --filter "name=nirmata-agent" --format "{{.ID}}" | head -1)
if [ -n "$nirmata_id" ]; then
    collect_container_logs "nirmata-agent" "$nirmata_id" "Nirmata Host Agent"
else
    echo "  ⚠ nirmata-agent container not found"
fi

echo ""

# Collect all containers if requested
if [ "$collect_all" = "--all-containers" ]; then
    echo "Collecting logs from all containers..."
    all_containers=$(podman ps -a --format "{{.ID}} {{.Names}}")
    
    echo "$all_containers" | while read -r cid cname; do
        # Skip if already collected
        if [[ ! "$cname" =~ ^(apiserver|controller-manager|etcd|scheduler|kubelet|proxy|nirmata-agent)$ ]]; then
            echo "Collecting logs from: $cname ($cid)"
            podman logs "$cid" --tail=5000 > "$output_dir/container-${cname}.log" 2>&1
            podman logs "$cid" --tail=5000 2>&1 | \
                grep -i "error\|failed\|timeout" > "$output_dir/container-${cname}-errors.log" 2>&1
        fi
    done
    echo ""
fi

# Collect system information
echo "Collecting system information..."

# Container status
podman ps -a > "$output_dir/containers-status.txt" 2>&1
echo "  ✓ Container status"

# Container stats (if running)
podman stats --no-stream > "$output_dir/containers-stats.txt" 2>&1
echo "  ✓ Container stats"

# Podman version
podman version > "$output_dir/podman-version.txt" 2>&1
echo "  ✓ Podman version"

# System logs (journalctl for podman/containerd)
if command -v journalctl &> /dev/null; then
    echo "Collecting system logs..."
    
    # Podman service logs
    if systemctl is-active --quiet podman 2>/dev/null; then
        journalctl -u podman -n 1000 --no-pager > "$output_dir/system-podman.log" 2>&1
        journalctl -u podman -n 1000 --no-pager | grep -i "error\|failed" > "$output_dir/system-podman-errors.log" 2>&1
        echo "  ✓ Podman service logs"
    fi
    
    # containerd logs (if exists)
    if systemctl is-active --quiet containerd 2>/dev/null; then
        journalctl -u containerd -n 1000 --no-pager > "$output_dir/system-containerd.log" 2>&1
        journalctl -u containerd -n 1000 --no-pager | grep -i "error\|failed\|timeout" > "$output_dir/system-containerd-errors.log" 2>&1
        echo "  ✓ containerd service logs"
    fi
    
    # System errors
    journalctl -p err -n 500 --no-pager > "$output_dir/system-errors.log" 2>&1
    echo "  ✓ System errors"
fi

# Disk space
df -h > "$output_dir/disk-usage.txt" 2>&1
echo "  ✓ Disk usage"

# Memory info
free -h > "$output_dir/memory-info.txt" 2>&1
echo "  ✓ Memory info"

# Network info
ip addr show > "$output_dir/network-info.txt" 2>&1
echo "  ✓ Network info"

# Container resource usage
echo "Collecting container resource details..."
for container in apiserver controller-manager etcd scheduler kubelet proxy; do
    cid=$(podman ps -a --filter "name=$container" --format "{{.ID}}" | head -1)
    if [ -n "$cid" ]; then
        podman inspect "$cid" --format '{{json .}}' | jq '{State: .State, Config: .Config, HostConfig: .HostConfig}' > "$output_dir/${container}-details.json" 2>&1
    fi
done

# Create summary
echo ""
echo "Creating summary..."
cat > "$output_dir/SUMMARY.txt" <<EOF
Podman Container Log Collection Summary
======================================

Collection Date: $(date)
Hostname: $(hostname)
Node IP: $(hostname -I | awk '{print $1}')

Containers Found:
EOF

podman ps -a --format "{{.Names}}\t{{.Status}}\t{{.Image}}" >> "$output_dir/SUMMARY.txt" 2>&1

cat >> "$output_dir/SUMMARY.txt" <<EOF

Files Collected:
- kube-apiserver.log (full logs)
- kube-apiserver-errors.log (errors only)
- kube-controller-manager.log (full logs)
- kube-controller-manager-errors.log (errors only)
- etcd.log (full logs)
- etcd-errors.log (errors only)
- kube-scheduler.log (full logs)
- kubelet.log (full logs)
- kube-proxy.log (full logs)
- nirmata-agent.log (full logs)
- containers-status.txt (all containers)
- containers-stats.txt (resource usage)
- system-podman.log (podman service logs)
- system-containerd.log (containerd service logs)
- system-errors.log (system errors)
- disk-usage.txt (disk space)
- memory-info.txt (memory usage)
- network-info.txt (network configuration)

Key Files to Review for Namespace Issues:
1. kube-apiserver-errors.log - Check for APIService errors, 503 errors
2. kube-controller-manager-errors.log - Check for namespace controller errors
3. etcd-errors.log - Check for performance issues, timeouts
4. system-containerd-errors.log - Check for container runtime issues

Next Steps:
1. Review kube-apiserver-errors.log for APIService errors
2. Review kube-controller-manager-errors.log for namespace deletion errors
3. Review etcd-errors.log for performance issues
4. Check containers-status.txt for container health
5. If using kubectl, run: ./collect-cluster-logs.sh <kubeconfig>
EOF

echo "  ✓ Summary created"

echo ""
echo "=========================================="
echo "Log Collection Complete"
echo "=========================================="
echo ""
echo "Logs saved to: $output_dir"
echo ""
echo "Key files to review for namespace termination issues:"
echo "  1. kube-apiserver-errors.log - API server errors"
echo "  2. kube-controller-manager-errors.log - Controller errors"
echo "  3. etcd-errors.log - etcd performance issues"
echo "  4. containers-status.txt - Container health"
echo ""
echo "To collect from all nodes, run this script on each node:"
echo "  scp collect-podman-logs.sh <node>:/tmp/"
echo "  ssh <node> 'bash /tmp/collect-podman-logs.sh'"
echo ""
