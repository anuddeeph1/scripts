#!/bin/bash

# Cluster Log Collection Script
# Collects all relevant logs for diagnosing namespace termination issues

if [ $# -lt 1 ]; then
    echo "Usage: $0 kubeconfig [output-dir]"
    echo ""
    echo "* kubeconfig: Absolute path of kubeconfig file for the cluster"
    echo "* output-dir: (Optional) Directory to save logs. Default: ./cluster-logs-<timestamp>"
    echo ""
    echo "Eg: $0 /home/user/.kube/config"
    exit 1
fi

kubeconfig=$1
output_dir=${2:-"./cluster-logs-$(date +%Y%m%d-%H%M%S)"}

mkdir -p "$output_dir"

echo "Collecting cluster logs..."
echo "Output directory: $output_dir"
echo ""

# API Server logs
echo "Collecting API Server logs..."
api_pods=$(kubectl --kubeconfig=$kubeconfig get pods -n kube-system -l component=kube-apiserver --no-headers 2>/dev/null | awk '{print $1}')
if [ -n "$api_pods" ]; then
    first_pod=$(echo "$api_pods" | head -1)
    kubectl --kubeconfig=$kubeconfig logs -n kube-system "$first_pod" --tail=5000 > "$output_dir/apiserver.log" 2>&1
    echo "  ✓ Collected from pod: $first_pod"
    
    # Also get errors only
    kubectl --kubeconfig=$kubeconfig logs -n kube-system "$first_pod" --tail=5000 2>&1 | \
        grep -i "error\|failed\|503\|timeout\|apiservice\|service unavailable" > "$output_dir/apiserver-errors.log" 2>&1
    echo "  ✓ Extracted errors to apiserver-errors.log"
else
    echo "  ⚠ API Server pods not found (may be static pods - check master node)"
    echo "  Run on master: journalctl -u kube-apiserver -n 5000 > apiserver.log" > "$output_dir/apiserver-instructions.txt"
fi

# Controller Manager logs
echo "Collecting Controller Manager logs..."
cm_pods=$(kubectl --kubeconfig=$kubeconfig get pods -n kube-system -l component=kube-controller-manager --no-headers 2>/dev/null | awk '{print $1}')
if [ -n "$cm_pods" ]; then
    first_pod=$(echo "$cm_pods" | head -1)
    kubectl --kubeconfig=$kubeconfig logs -n kube-system "$first_pod" --tail=5000 > "$output_dir/controller-manager.log" 2>&1
    echo "  ✓ Collected from pod: $first_pod"
    
    # Errors only
    kubectl --kubeconfig=$kubeconfig logs -n kube-system "$first_pod" --tail=5000 2>&1 | \
        grep -i "error\|failed\|namespace\|finalizer\|delete" > "$output_dir/controller-manager-errors.log" 2>&1
    echo "  ✓ Extracted errors to controller-manager-errors.log"
else
    echo "  ⚠ Controller Manager pods not found (may be static pods)"
    echo "  Run on master: journalctl -u kube-controller-manager -n 5000 > controller-manager.log" > "$output_dir/controller-manager-instructions.txt"
fi

# etcd logs
echo "Collecting etcd logs..."
etcd_pods=$(kubectl --kubeconfig=$kubeconfig get pods -n kube-system -l component=etcd --no-headers 2>/dev/null | awk '{print $1}')
if [ -n "$etcd_pods" ]; then
    first_pod=$(echo "$etcd_pods" | head -1)
    kubectl --kubeconfig=$kubeconfig logs -n kube-system "$first_pod" --tail=5000 > "$output_dir/etcd.log" 2>&1
    echo "  ✓ Collected from pod: $first_pod"
    
    # Errors only
    kubectl --kubeconfig=$kubeconfig logs -n kube-system "$first_pod" --tail=5000 2>&1 | \
        grep -i "error\|failed\|slow\|timeout\|connection" > "$output_dir/etcd-errors.log" 2>&1
    echo "  ✓ Extracted errors to etcd-errors.log"
else
    echo "  ⚠ etcd pods not found (likely static pods)"
    echo "  Run on master: journalctl -u etcd -n 5000 > etcd.log" > "$output_dir/etcd-instructions.txt"
fi

# Scheduler logs
echo "Collecting Scheduler logs..."
scheduler_pods=$(kubectl --kubeconfig=$kubeconfig get pods -n kube-system -l component=kube-scheduler --no-headers 2>/dev/null | awk '{print $1}')
if [ -n "$scheduler_pods" ]; then
    first_pod=$(echo "$scheduler_pods" | head -1)
    kubectl --kubeconfig=$kubeconfig logs -n kube-system "$first_pod" --tail=5000 > "$output_dir/scheduler.log" 2>&1
    echo "  ✓ Collected from pod: $first_pod"
fi

# Cluster state
echo "Collecting cluster state..."

# APIServices
kubectl --kubeconfig=$kubeconfig get apiservices -o yaml > "$output_dir/apiservices.yaml" 2>&1
echo "  ✓ APIServices status"

# Unavailable APIServices
kubectl --kubeconfig=$kubeconfig get apiservices | grep -v "True" > "$output_dir/unavailable-apiservices.txt" 2>&1
echo "  ✓ Unavailable APIServices list"

# Webhooks
kubectl --kubeconfig=$kubeconfig get mutatingwebhookconfigurations,validatingwebhookconfigurations -o yaml > "$output_dir/webhooks.yaml" 2>&1
echo "  ✓ Webhook configurations"

# Namespaces
kubectl --kubeconfig=$kubeconfig get ns -o yaml > "$output_dir/namespaces.yaml" 2>&1
echo "  ✓ Namespaces status"

# Stuck namespaces
kubectl --kubeconfig=$kubeconfig get ns | grep Terminating > "$output_dir/stuck-namespaces.txt" 2>&1
echo "  ✓ Stuck namespaces list"

# Component status
kubectl --kubeconfig=$kubeconfig get componentstatuses > "$output_dir/component-status.txt" 2>&1
echo "  ✓ Component status"

# Node status
kubectl --kubeconfig=$kubeconfig get nodes -o wide > "$output_dir/nodes.txt" 2>&1
echo "  ✓ Node status"

# System pods
kubectl --kubeconfig=$kubeconfig get pods -n kube-system -o wide > "$output_dir/kube-system-pods.txt" 2>&1
echo "  ✓ kube-system pods"

# Events
kubectl --kubeconfig=$kubeconfig get events -A --sort-by='.lastTimestamp' | tail -100 > "$output_dir/recent-events.txt" 2>&1
echo "  ✓ Recent events"

# Create summary
echo ""
echo "Creating summary..."
cat > "$output_dir/SUMMARY.txt" <<EOF
Cluster Log Collection Summary
==============================

Collection Date: $(date)
Kubeconfig: $kubeconfig

Files Collected:
- apiserver.log (full logs)
- apiserver-errors.log (errors only)
- controller-manager.log (full logs)
- controller-manager-errors.log (errors only)
- etcd.log (full logs)
- etcd-errors.log (errors only)
- scheduler.log (full logs)
- apiservices.yaml (APIService status)
- unavailable-apiservices.txt (broken APIServices)
- webhooks.yaml (webhook configurations)
- namespaces.yaml (all namespaces)
- stuck-namespaces.txt (stuck namespaces)
- component-status.txt (component health)
- nodes.txt (node status)
- kube-system-pods.txt (system pods)
- recent-events.txt (recent cluster events)

Key Files to Review:
1. unavailable-apiservices.txt - Check for broken APIServices
2. stuck-namespaces.txt - List of stuck namespaces
3. apiserver-errors.log - API server issues
4. controller-manager-errors.log - Controller issues
5. etcd-errors.log - etcd issues

Next Steps:
1. Review unavailable-apiservices.txt
2. Check apiserver-errors.log for APIService errors
3. Review controller-manager-errors.log for namespace controller issues
4. Check etcd-errors.log for performance issues
5. Run: ./cluster-health-check.sh $kubeconfig
EOF

echo "  ✓ Summary created"

echo ""
echo "=========================================="
echo "Log Collection Complete"
echo "=========================================="
echo ""
echo "Logs saved to: $output_dir"
echo ""
echo "Key files to review:"
echo "  1. unavailable-apiservices.txt - Broken APIServices"
echo "  2. stuck-namespaces.txt - Stuck namespaces"
echo "  3. apiserver-errors.log - API server errors"
echo "  4. controller-manager-errors.log - Controller errors"
echo "  5. etcd-errors.log - etcd errors"
echo ""
echo "For static pods (API server, etcd, controller-manager on master):"
echo "  SSH to master node and run:"
echo "    journalctl -u kube-apiserver -n 5000 > apiserver.log"
echo "    journalctl -u kube-controller-manager -n 5000 > controller-manager.log"
echo "    journalctl -u etcd -n 5000 > etcd.log"
echo "    journalctl -u containerd -n 5000 > containerd.log"
echo ""
