#!/bin/bash

# Collect Logs from All Nodes Script
# For Nirmata-managed clusters - collects logs from all nodes via SSH

if [ $# -lt 2 ]; then
    echo "Usage: $0 kubeconfig node-list-file [ssh-user] [ssh-key]"
    echo ""
    echo "* kubeconfig: Absolute path of kubeconfig file for the cluster"
    echo "* node-list-file: File containing list of node hostnames/IPs (one per line)"
    echo "* ssh-user: (Optional) SSH user. Default: root"
    echo "* ssh-key: (Optional) SSH private key path"
    echo ""
    echo "Example node-list-file (nodes.txt):"
    echo "  GLCHBS-SS220643"
    echo "  GLCHBS-SS220644"
    echo "  10.165.174.225"
    echo ""
    echo "Eg: $0 /path/to/kubeconfig nodes.txt"
    echo "Eg: $0 /path/to/kubeconfig nodes.txt root /path/to/id_rsa"
    exit 1
fi

kubeconfig=$1
node_list_file=$2
ssh_user=${3:-"root"}
ssh_key=${4:-""}

if [ ! -f "$node_list_file" ]; then
    echo "Error: Node list file '$node_list_file' not found"
    exit 1
fi

output_base_dir="./cluster-logs-all-nodes-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$output_base_dir"

echo "=========================================="
echo "Multi-Node Log Collection"
echo "=========================================="
echo "Kubeconfig: $kubeconfig"
echo "Node list: $node_list_file"
echo "SSH User: $ssh_user"
echo "Output directory: $output_base_dir"
echo ""

# Copy collection script to nodes
script_name="collect-podman-logs.sh"
if [ ! -f "$script_name" ]; then
    echo "Error: $script_name not found in current directory"
    exit 1
fi

# Read nodes from file
nodes=()
while IFS= read -r line || [ -n "$line" ]; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    nodes+=("$line")
done < "$node_list_file"

if [ ${#nodes[@]} -eq 0 ]; then
    echo "Error: No valid nodes found in $node_list_file"
    exit 1
fi

echo "Found ${#nodes[@]} node(s) to collect logs from:"
for node in "${nodes[@]}"; do
    echo "  - $node"
done
echo ""

# SSH options
ssh_opts="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
if [ -n "$ssh_key" ]; then
    ssh_opts="$ssh_opts -i $ssh_key"
fi

# Function to collect logs from a node
collect_from_node() {
    local node=$1
    local node_output_dir="$output_base_dir/$node"
    mkdir -p "$node_output_dir"
    
    echo "=========================================="
    echo "Collecting logs from: $node"
    echo "=========================================="
    
    # Test SSH connection
    if ! ssh $ssh_opts "${ssh_user}@${node}" "echo 'Connection successful'" > /dev/null 2>&1; then
        echo "  ❌ Cannot connect to $node via SSH"
        echo "Connection failed" > "$node_output_dir/ERROR-connection-failed.txt"
        return 1
    fi
    
    echo "  ✓ SSH connection successful"
    
    # Copy script to node
    echo "  Copying collection script..."
    scp $ssh_opts "$script_name" "${ssh_user}@${node}:/tmp/" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "  ⚠ Failed to copy script, trying alternative method..."
    fi
    
    # Run collection script on node
    echo "  Running log collection on node..."
    ssh $ssh_opts "${ssh_user}@${node}" "bash /tmp/$script_name /tmp/podman-logs-${node}" > "$node_output_dir/collection-output.txt" 2>&1
    
    # Download collected logs
    echo "  Downloading logs..."
    scp $ssh_opts -r "${ssh_user}@${node}:/tmp/podman-logs-${node}/*" "$node_output_dir/" > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo "  ✓ Logs collected successfully"
        
        # Clean up remote files
        ssh $ssh_opts "${ssh_user}@${node}" "rm -rf /tmp/podman-logs-${node} /tmp/$script_name" > /dev/null 2>&1
    else
        echo "  ⚠ Some logs may not have been downloaded"
    fi
    
    # Get node information
    echo "  Collecting node information..."
    ssh $ssh_opts "${ssh_user}@${node}" "hostname; uname -a; uptime" > "$node_output_dir/node-info.txt" 2>&1
    
    echo ""
}

# Collect from each node
for node in "${nodes[@]}"; do
    collect_from_node "$node"
done

# Collect cluster-level information using kubectl
echo "=========================================="
echo "Collecting Cluster-Level Information"
echo "=========================================="
echo ""

cluster_info_dir="$output_base_dir/cluster-info"
mkdir -p "$cluster_info_dir"

if [ -f "$kubeconfig" ]; then
    export KUBECONFIG="$kubeconfig"
    
    echo "Collecting cluster state..."
    
    # APIServices
    kubectl get apiservices -o yaml > "$cluster_info_dir/apiservices.yaml" 2>&1
    kubectl get apiservices | grep -v "True" > "$cluster_info_dir/unavailable-apiservices.txt" 2>&1
    echo "  ✓ APIServices"
    
    # Webhooks
    kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations -o yaml > "$cluster_info_dir/webhooks.yaml" 2>&1
    echo "  ✓ Webhooks"
    
    # Namespaces
    kubectl get ns -o yaml > "$cluster_info_dir/namespaces.yaml" 2>&1
    kubectl get ns | grep Terminating > "$cluster_info_dir/stuck-namespaces.txt" 2>&1
    echo "  ✓ Namespaces"
    
    # Nodes
    kubectl get nodes -o wide > "$cluster_info_dir/nodes.txt" 2>&1
    kubectl get nodes -o yaml > "$cluster_info_dir/nodes.yaml" 2>&1
    echo "  ✓ Nodes"
    
    # System pods
    kubectl get pods -n kube-system -o wide > "$cluster_info_dir/kube-system-pods.txt" 2>&1
    echo "  ✓ kube-system pods"
    
    # Events
    kubectl get events -A --sort-by='.lastTimestamp' | tail -200 > "$cluster_info_dir/recent-events.txt" 2>&1
    echo "  ✓ Recent events"
    
    # Component status
    kubectl get componentstatuses > "$cluster_info_dir/component-status.txt" 2>&1
    echo "  ✓ Component status"
else
    echo "  ⚠ Kubeconfig not found, skipping cluster-level collection"
fi

# Create master summary
echo ""
echo "Creating master summary..."
cat > "$output_base_dir/MASTER-SUMMARY.txt" <<EOF
Multi-Node Log Collection Summary
==================================

Collection Date: $(date)
Kubeconfig: $kubeconfig
Nodes Collected: ${#nodes[@]}

Nodes:
EOF

for node in "${nodes[@]}"; do
    echo "  - $node" >> "$output_base_dir/MASTER-SUMMARY.txt"
done

cat >> "$output_base_dir/MASTER-SUMMARY.txt" <<EOF

Directory Structure:
$output_base_dir/
├── cluster-info/          (Cluster-level information)
│   ├── apiservices.yaml
│   ├── unavailable-apiservices.txt
│   ├── webhooks.yaml
│   ├── namespaces.yaml
│   ├── stuck-namespaces.txt
│   └── ...
│
└── <node-name>/           (Per-node logs)
    ├── kube-apiserver.log
    ├── kube-apiserver-errors.log
    ├── kube-controller-manager.log
    ├── kube-controller-manager-errors.log
    ├── etcd.log
    ├── etcd-errors.log
    └── ...

Key Files to Review:
1. cluster-info/unavailable-apiservices.txt - Broken APIServices
2. cluster-info/stuck-namespaces.txt - Stuck namespaces
3. <node>/kube-apiserver-errors.log - API server errors per node
4. <node>/kube-controller-manager-errors.log - Controller errors per node
5. <node>/etcd-errors.log - etcd errors per node

Analysis Steps:
1. Check cluster-info/unavailable-apiservices.txt for broken APIServices
2. Review kube-apiserver-errors.log from all nodes for APIService errors
3. Review kube-controller-manager-errors.log for namespace controller issues
4. Review etcd-errors.log for performance issues
5. Compare logs across nodes to identify patterns
EOF

echo "  ✓ Master summary created"

echo ""
echo "=========================================="
echo "Collection Complete"
echo "=========================================="
echo ""
echo "All logs saved to: $output_base_dir"
echo ""
echo "Quick analysis:"
echo "  1. Check broken APIServices:"
echo "     cat $output_base_dir/cluster-info/unavailable-apiservices.txt"
echo ""
echo "  2. Check stuck namespaces:"
echo "     cat $output_base_dir/cluster-info/stuck-namespaces.txt"
echo ""
echo "  3. Review API server errors (example from first node):"
echo "     cat $output_base_dir/${nodes[0]}/kube-apiserver-errors.log"
echo ""
