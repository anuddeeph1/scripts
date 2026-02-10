#!/bin/bash

# Kubernetes Cluster Information Collection Script
# Collects cluster-level info via kubectl (excludes master component logs - use collect-podman-logs.sh for those)
# This complements the podman log collection script
#
# IMPORTANT: This script is READ-ONLY and does NOT modify or delete anything
# It only collects information using kubectl get commands
# No resources will be deleted, modified, or changed in any way

if [ $# -lt 1 ]; then
    echo "Usage: $0 kubeconfig [output-dir]"
    echo ""
    echo "* kubeconfig: Absolute path of kubeconfig file for the cluster"
    echo "* output-dir: (Optional) Directory to save logs. Default: ./kubectl-cluster-info-<timestamp>"
    echo ""
    echo "Eg: $0 /home/user/.kube/config"
    echo "Eg: $0 /home/user/.kube/config /tmp/cluster-info"
    exit 1
fi

kubeconfig=$1
output_dir=${2:-"./kubectl-cluster-info-$(date +%Y%m%d-%H%M%S)"}

mkdir -p "$output_dir"

echo "=========================================="
echo "Kubernetes Cluster Information Collection"
echo "=========================================="
echo "Kubeconfig: $kubeconfig"
echo "Output directory: $output_dir"
echo ""
echo "⚠️  IMPORTANT: This script is READ-ONLY"
echo "   - Only collects information (kubectl get commands)"
echo "   - Does NOT delete, modify, or change anything"
echo "   - Safe to run on production clusters"
echo ""
echo "Note: Master component logs (apiserver, controller-manager, etcd, scheduler)"
echo "      should be collected using collect-podman-logs.sh on each node"
echo ""

# Set kubeconfig
export KUBECONFIG="$kubeconfig"

# Test kubectl connection
if ! kubectl cluster-info &>/dev/null; then
    echo "❌ Cannot connect to cluster. Please check kubeconfig."
    exit 1
fi

echo "✓ Connected to cluster"
echo ""

# Function to collect resource with error handling
collect_resource() {
    local resource=$1
    local output_file=$2
    local description=$3
    
    echo "Collecting: $description"
    kubectl get "$resource" -o yaml > "$output_file" 2>&1
    if [ $? -eq 0 ]; then
        echo "  ✓ Collected"
    else
        echo "  ⚠ Error collecting (may not exist or no permissions)"
    fi
}

# Cluster Information
echo "=========================================="
echo "1. Cluster Information"
echo "=========================================="
echo ""

kubectl cluster-info > "$output_dir/cluster-info.txt" 2>&1
echo "  ✓ Cluster info"

kubectl version -o yaml > "$output_dir/kubectl-version.yaml" 2>&1
echo "  ✓ Kubernetes version"

kubectl get componentstatuses > "$output_dir/component-status.txt" 2>&1
echo "  ✓ Component status"

# APIServices (CRITICAL for namespace issues)
echo ""
echo "=========================================="
echo "2. APIServices (CRITICAL)"
echo "=========================================="
echo ""

collect_resource "apiservices" "$output_dir/apiservices.yaml" "APIServices (full)"
kubectl get apiservices > "$output_dir/apiservices-list.txt" 2>&1
kubectl get apiservices | grep -v "True" > "$output_dir/unavailable-apiservices.txt" 2>&1

unavailable_count=$(cat "$output_dir/unavailable-apiservices.txt" | grep -v "^NAME" | wc -l | tr -d ' ')
if [ "$unavailable_count" -gt 0 ]; then
    echo "  🔴 Found $unavailable_count unavailable APIService(s) - This may be blocking namespace deletion!"
    echo ""
    echo "  Unavailable APIServices:"
    cat "$output_dir/unavailable-apiservices.txt" | grep -v "^NAME" | awk '{print "    - " $1 " (" $2 ")"}'
else
    echo "  ✓ All APIServices are available"
fi

# Webhooks
echo ""
echo "=========================================="
echo "3. Webhooks"
echo "=========================================="
echo ""

collect_resource "mutatingwebhookconfigurations" "$output_dir/mutating-webhooks.yaml" "Mutating Webhooks"
collect_resource "validatingwebhookconfigurations" "$output_dir/validating-webhooks.yaml" "Validating Webhooks"

kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations > "$output_dir/webhooks-list.txt" 2>&1
echo "  ✓ Webhook list"

# Namespaces
echo ""
echo "=========================================="
echo "4. Namespaces"
echo "=========================================="
echo ""

collect_resource "namespaces" "$output_dir/namespaces.yaml" "Namespaces (full)"
kubectl get ns > "$output_dir/namespaces-list.txt" 2>&1
kubectl get ns | grep Terminating > "$output_dir/stuck-namespaces.txt" 2>&1

stuck_count=$(cat "$output_dir/stuck-namespaces.txt" | wc -l | tr -d ' ')
if [ "$stuck_count" -gt 0 ]; then
    echo "  🔴 Found $stuck_count namespace(s) stuck in Terminating state!"
    echo ""
    echo "  Stuck namespaces:"
    cat "$output_dir/stuck-namespaces.txt" | awk '{print "    - " $1 " (for " $3 ")"}'
else
    echo "  ✓ No namespaces stuck in Terminating"
fi

# Nodes
echo ""
echo "=========================================="
echo "5. Nodes"
echo "=========================================="
echo ""

collect_resource "nodes" "$output_dir/nodes.yaml" "Nodes (full)"
kubectl get nodes -o wide > "$output_dir/nodes-list.txt" 2>&1
kubectl describe nodes > "$output_dir/nodes-describe.txt" 2>&1
echo "  ✓ Node information"

# Pods in kube-system (excluding master components)
echo ""
echo "=========================================="
echo "6. kube-system Pods (excluding master components)"
echo "=========================================="
echo ""

kubectl get pods -n kube-system -o wide > "$output_dir/kube-system-pods.txt" 2>&1
kubectl get pods -n kube-system -o yaml > "$output_dir/kube-system-pods.yaml" 2>&1

# Get logs from non-master component pods
echo "Collecting logs from kube-system pods (excluding master components)..."
kubectl get pods -n kube-system --no-headers 2>/dev/null | \
    grep -v -E "kube-apiserver|kube-controller-manager|kube-scheduler|etcd" | \
    awk '{print $1}' | while read pod; do
        namespace="kube-system"
        echo "  Collecting logs from: $pod"
        kubectl logs -n "$namespace" "$pod" --tail=5000 > "$output_dir/pod-${namespace}-${pod}.log" 2>&1
        kubectl logs -n "$namespace" "$pod" --tail=5000 2>&1 | \
            grep -i "error\|failed\|timeout" > "$output_dir/pod-${namespace}-${pod}-errors.log" 2>&1
    done

echo "  ✓ kube-system pods"

# All namespaces pods (summary)
echo ""
echo "=========================================="
echo "7. Pods Across All Namespaces"
echo "=========================================="
echo ""

kubectl get pods -A -o wide > "$output_dir/all-pods.txt" 2>&1
kubectl get pods -A --field-selector=status.phase!=Running > "$output_dir/non-running-pods.txt" 2>&1
echo "  ✓ Pod information"

# Events
echo ""
echo "=========================================="
echo "8. Events"
echo "=========================================="
echo ""

kubectl get events -A --sort-by='.lastTimestamp' | tail -500 > "$output_dir/recent-events.txt" 2>&1
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' | tail -200 > "$output_dir/warning-events.txt" 2>&1
echo "  ✓ Events"

# Resource Quotas and Limits
echo ""
echo "=========================================="
echo "9. Resource Quotas and Limits"
echo "=========================================="
echo ""

kubectl get resourcequotas -A > "$output_dir/resource-quotas.txt" 2>&1
kubectl get limitranges -A > "$output_dir/limit-ranges.txt" 2>&1
echo "  ✓ Resource quotas and limits"

# Persistent Volumes
echo ""
echo "=========================================="
echo "10. Persistent Volumes"
echo "=========================================="
echo ""

kubectl get pv > "$output_dir/persistent-volumes.txt" 2>&1
kubectl get pvc -A > "$output_dir/persistent-volume-claims.txt" 2>&1
echo "  ✓ Persistent volumes"

# Services
echo ""
echo "=========================================="
echo "11. Services"
echo "=========================================="
echo ""

kubectl get svc -A > "$output_dir/services.txt" 2>&1
kubectl get endpoints -A > "$output_dir/endpoints.txt" 2>&1
echo "  ✓ Services and endpoints"

# Custom Resources (CRDs)
echo ""
echo "=========================================="
echo "12. Custom Resource Definitions"
echo "=========================================="
echo ""

kubectl get crd > "$output_dir/custom-resource-definitions.txt" 2>&1
echo "  ✓ CRDs"

# Check for Kyverno CRDs specifically
if kubectl get crd | grep -q kyverno; then
    echo "  Found Kyverno CRDs - collecting instances..."
    for crd in $(kubectl get crd | grep kyverno | awk '{print $1}'); do
        echo "    Collecting: $crd"
        kubectl get "$crd" -A > "$output_dir/crd-${crd}.txt" 2>&1
    done
fi

# Check for Policy CRDs (wgpolicyk8s.io)
if kubectl get crd | grep -q wgpolicyk8s; then
    echo "  Found Policy CRDs - collecting instances..."
    for crd in $(kubectl get crd | grep wgpolicyk8s | awk '{print $1}'); do
        echo "    Collecting: $crd"
        kubectl get "$crd" -A > "$output_dir/crd-${crd}.txt" 2>&1
    done
fi

# RBAC
echo ""
echo "=========================================="
echo "13. RBAC"
echo "=========================================="
echo ""

kubectl get clusterroles > "$output_dir/cluster-roles.txt" 2>&1
kubectl get clusterrolebindings > "$output_dir/cluster-role-bindings.txt" 2>&1
kubectl get roles -A > "$output_dir/roles.txt" 2>&1
kubectl get rolebindings -A > "$output_dir/role-bindings.txt" 2>&1
echo "  ✓ RBAC resources"

# Network Policies
echo ""
echo "=========================================="
echo "14. Network Policies"
echo "=========================================="
echo ""

kubectl get networkpolicies -A > "$output_dir/network-policies.txt" 2>&1
echo "  ✓ Network policies"

# CNI (Container Network Interface) - Diagnosis for Namespace Termination Issues
echo ""
echo "=========================================="
echo "15. CNI (Container Network Interface) - Diagnosis"
echo "=========================================="
echo ""

# Identify which CNI is installed
echo "Identifying installed CNI..."
detected_cni=""
cni_namespaces=""

# Check for Calico
if kubectl get pods -A 2>/dev/null | grep -qi calico; then
    detected_cni="Calico"
    echo "  ✓ Detected: Calico"
    cni_namespaces="$cni_namespaces $(kubectl get pods -A 2>/dev/null | grep -i calico | awk '{print $1}' | sort -u | tr '\n' ' ')"
fi

# Check for Cilium
if kubectl get pods -A 2>/dev/null | grep -qi cilium; then
    if [ -z "$detected_cni" ]; then
        detected_cni="Cilium"
    else
        detected_cni="$detected_cni, Cilium"
    fi
    echo "  ✓ Detected: Cilium"
    cni_namespaces="$cni_namespaces $(kubectl get pods -A 2>/dev/null | grep -i cilium | awk '{print $1}' | sort -u | tr '\n' ' ')"
fi

# Check for Flannel
if kubectl get pods -A 2>/dev/null | grep -qi flannel; then
    if [ -z "$detected_cni" ]; then
        detected_cni="Flannel"
    else
        detected_cni="$detected_cni, Flannel"
    fi
    echo "  ✓ Detected: Flannel"
    cni_namespaces="$cni_namespaces $(kubectl get pods -A 2>/dev/null | grep -i flannel | awk '{print $1}' | sort -u | tr '\n' ' ')"
fi

# Check for Weave
if kubectl get pods -A 2>/dev/null | grep -qi weave; then
    if [ -z "$detected_cni" ]; then
        detected_cni="Weave"
    else
        detected_cni="$detected_cni, Weave"
    fi
    echo "  ✓ Detected: Weave"
    cni_namespaces="$cni_namespaces $(kubectl get pods -A 2>/dev/null | grep -i weave | awk '{print $1}' | sort -u | tr '\n' ' ')"
fi

# Check for other CNIs
for cni in canal kube-router romana contiv; do
    if kubectl get pods -A 2>/dev/null | grep -qi "$cni"; then
        if [ -z "$detected_cni" ]; then
            detected_cni="$cni"
        else
            detected_cni="$detected_cni, $cni"
        fi
        echo "  ✓ Detected: $cni"
        cni_namespaces="$cni_namespaces $(kubectl get pods -A 2>/dev/null | grep -i "$cni" | awk '{print $1}' | sort -u | tr '\n' ' ')"
    fi
done

# Remove duplicates and clean up
cni_namespaces=$(echo "$cni_namespaces" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')

if [ -z "$detected_cni" ]; then
    echo "  ⚠ No CNI detected - this is unusual and may indicate a problem"
    detected_cni="Unknown/Not Detected"
else
    echo ""
    echo "  Installed CNI: $detected_cni"
    echo "  CNI namespaces: $(echo $cni_namespaces | tr ' ' ',')"
fi

# Save CNI identification
echo "$detected_cni" > "$output_dir/cni-detected.txt" 2>&1
echo "$cni_namespaces" > "$output_dir/cni-namespaces.txt" 2>&1

if [ -n "$cni_namespaces" ]; then
    echo "  Found CNI components in: $(echo $cni_namespaces | tr ' ' ',')"
    echo ""
    
    # Collect CNI pods
    echo "Collecting CNI pod information..."
    for ns in $cni_namespaces; do
        kubectl get pods -n "$ns" -o wide | grep -iE "calico|flannel|cilium|weave|canal|kube-router|romana|contiv|network" > "$output_dir/cni-pods-${ns}.txt" 2>&1
    done
    
    # Collect CNI pod logs
    echo "Collecting CNI pod logs..."
    for ns in $cni_namespaces; do
        kubectl get pods -n "$ns" --no-headers 2>/dev/null | \
            grep -iE "calico|flannel|cilium|weave|canal|kube-router|romana|contiv|network" | \
            awk '{print $1}' | while read pod; do
                echo "  Collecting logs from: $ns/$pod"
                kubectl logs -n "$ns" "$pod" --tail=5000 > "$output_dir/cni-pod-${ns}-${pod}.log" 2>&1
                kubectl logs -n "$ns" "$pod" --tail=5000 2>&1 | \
                    grep -i "error\|failed\|timeout\|panic\|fatal" > "$output_dir/cni-pod-${ns}-${pod}-errors.log" 2>&1
            done
    done
    
    # Collect CNI DaemonSets
    echo "Collecting CNI DaemonSets..."
    for ns in $cni_namespaces; do
        kubectl get daemonsets -n "$ns" 2>/dev/null | \
            grep -iE "calico|flannel|cilium|weave|canal|kube-router|romana|contiv|network" > "$output_dir/cni-daemonsets-${ns}.txt" 2>&1
    done
    
    # Collect CNI Deployments
    echo "Collecting CNI Deployments..."
    for ns in $cni_namespaces; do
        kubectl get deployments -n "$ns" 2>/dev/null | \
            grep -iE "calico|flannel|cilium|weave|canal|kube-router|romana|contiv|network" > "$output_dir/cni-deployments-${ns}.txt" 2>&1
    done
    
    # Collect CNI ConfigMaps
    echo "Collecting CNI ConfigMaps..."
    for ns in $cni_namespaces; do
        kubectl get configmaps -n "$ns" 2>/dev/null | \
            grep -iE "calico|flannel|cilium|weave|canal|kube-router|romana|contiv|network|cni" > "$output_dir/cni-configmaps-${ns}.txt" 2>&1
        
        # Get CNI ConfigMap details
        kubectl get configmaps -n "$ns" 2>/dev/null | \
            grep -iE "calico|flannel|cilium|weave|canal|kube-router|romana|contiv|network|cni" | \
            awk '{print $1}' | while read cm; do
                kubectl get configmap "$cm" -n "$ns" -o yaml > "$output_dir/cni-configmap-${ns}-${cm}.yaml" 2>&1
            done
    done
    
    # Collect CNI Services
    echo "Collecting CNI Services..."
    for ns in $cni_namespaces; do
        kubectl get svc -n "$ns" 2>/dev/null | \
            grep -iE "calico|flannel|cilium|weave|canal|kube-router|romana|contiv|network" > "$output_dir/cni-services-${ns}.txt" 2>&1
    done
    
    # Calico-specific resources
    if kubectl get pods -A | grep -qi calico; then
        echo "Collecting Calico-specific resources..."
        
        # Calico IPAM blocks
        if kubectl api-resources | grep -q "ipamblocks"; then
            kubectl get ipamblocks -A > "$output_dir/calico-ipamblocks.txt" 2>&1
        fi
        
        # Calico IP pools
        if kubectl api-resources | grep -q "ippools"; then
            kubectl get ippools -A > "$output_dir/calico-ippools.txt" 2>&1
            kubectl get ippools -A -o yaml > "$output_dir/calico-ippools.yaml" 2>&1
        fi
        
        # Calico network policies
        if kubectl api-resources | grep -q "networkpolicies.crd"; then
            kubectl get networkpolicies.crd -A > "$output_dir/calico-networkpolicies.txt" 2>&1
        fi
        
        # Calico BGP peers
        if kubectl api-resources | grep -q "bgppeers"; then
            kubectl get bgppeers -A > "$output_dir/calico-bgppeers.txt" 2>&1
        fi
    fi
    
    # Cilium-specific resources
    if kubectl get pods -A | grep -qi cilium; then
        echo "Collecting Cilium-specific resources..."
        
        # Cilium network policies
        if kubectl api-resources | grep -q "ciliumnetworkpolicies"; then
            kubectl get ciliumnetworkpolicies -A > "$output_dir/cilium-networkpolicies.txt" 2>&1
        fi
        
        # Cilium endpoints
        if kubectl api-resources | grep -q "ciliumendpoints"; then
            kubectl get ciliumendpoints -A > "$output_dir/cilium-endpoints.txt" 2>&1
        fi
        
        # Cilium identities
        if kubectl api-resources | grep -q "ciliumidentities"; then
            kubectl get ciliumidentities -A > "$output_dir/cilium-identities.txt" 2>&1
        fi
    fi
    
    echo "  ✓ CNI information collected"
    
    # CNI Health Check and Analysis
    echo ""
    echo "Analyzing CNI health and namespace termination impact..."
    
    # Check CNI pod status
    cni_unhealthy=0
    cni_not_running=0
    
    for ns in $cni_namespaces; do
        cni_pods=$(kubectl get pods -n "$ns" 2>/dev/null | \
            grep -iE "calico|flannel|cilium|weave|canal|kube-router|romana|contiv|network" | \
            grep -v "Running\|Completed" | wc -l | tr -d ' ')
        
        if [ "$cni_pods" -gt 0 ]; then
            cni_not_running=$((cni_not_running + cni_pods))
            echo "  ⚠ Found $cni_pods non-running CNI pod(s) in namespace $ns"
            kubectl get pods -n "$ns" 2>/dev/null | \
                grep -iE "calico|flannel|cilium|weave|canal|kube-router|romana|contiv|network" | \
                grep -v "Running\|Completed" | awk '{print "    - " $1 " (" $3 ")"}' >> "$output_dir/cni-unhealthy-pods.txt" 2>&1
        fi
        
        # Check for CrashLoopBackOff
        crash_loop=$(kubectl get pods -n "$ns" 2>/dev/null | \
            grep -iE "calico|flannel|cilium|weave|canal|kube-router|romana|contiv|network" | \
            grep -i "CrashLoopBackOff\|Error" | wc -l | tr -d ' ')
        
        if [ "$crash_loop" -gt 0 ]; then
            cni_unhealthy=$((cni_unhealthy + crash_loop))
            echo "  🔴 Found $crash_loop CNI pod(s) in CrashLoopBackOff/Error in namespace $ns"
        fi
    done
    
    # Check CNI DaemonSet status
    echo ""
    echo "Checking CNI DaemonSet status..."
    for ns in $cni_namespaces; do
        ds_list=$(kubectl get daemonsets -n "$ns" 2>/dev/null | \
            grep -iE "calico|flannel|cilium|weave|canal|kube-router|romana|contiv|network" | \
            awk 'NR>1 {print $1}')
        
        if [ -n "$ds_list" ]; then
            echo "$ds_list" | while read ds; do
                desired=$(kubectl get daemonset "$ds" -n "$ns" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
                ready=$(kubectl get daemonset "$ds" -n "$ns" -o jsonpath='{.status.numberReady}' 2>/dev/null)
                
                if [ -n "$desired" ] && [ -n "$ready" ] && [ "$desired" != "$ready" ]; then
                    echo "  ⚠ DaemonSet $ds in $ns: $ready/$desired pods ready"
                    echo "DaemonSet $ds in $ns: $ready/$desired pods ready" >> "$output_dir/cni-daemonset-issues.txt" 2>&1
                else
                    echo "  ✓ DaemonSet $ds in $ns: All pods ready ($ready/$desired)"
                fi
            done
        fi
    done
    
    # Check for CNI-related network issues that could block namespace deletion
    echo ""
    echo "Checking for CNI issues that could block namespace deletion..."
    
    # Check for pods stuck in Terminating with network issues
    terminating_pods_with_network=$(kubectl get pods -A --field-selector=status.phase!=Running 2>/dev/null | \
        grep -i "Terminating" | wc -l | tr -d ' ')
    
    if [ "$terminating_pods_with_network" -gt 0 ]; then
        echo "  ⚠ Found $terminating_pods_with_network pod(s) in Terminating state"
        echo "  This could indicate CNI issues preventing pod cleanup"
        kubectl get pods -A --field-selector=status.phase!=Running 2>/dev/null | \
            grep -i "Terminating" > "$output_dir/cni-terminating-pods.txt" 2>&1
    fi
    
    # Check for network-related events
    network_errors=$(kubectl get events -A 2>/dev/null | \
        grep -iE "network.*error|network.*failed|cni.*error|cni.*failed|network.*timeout" | \
        tail -50 | wc -l | tr -d ' ')
    
    if [ "$network_errors" -gt 0 ]; then
        echo "  ⚠ Found $network_errors network-related error events"
        kubectl get events -A 2>/dev/null | \
            grep -iE "network.*error|network.*failed|cni.*error|cni.*failed|network.*timeout" | \
            tail -50 > "$output_dir/cni-network-errors.txt" 2>&1
    fi
    
    # CNI Analysis Summary
    echo ""
    echo "CNI Health Summary:"
    if [ "$cni_unhealthy" -gt 0 ] || [ "$cni_not_running" -gt 0 ]; then
        echo "  🔴 CNI Health Issues Detected:"
        echo "     - Unhealthy/CrashLoop pods: $cni_unhealthy"
        echo "     - Non-running pods: $cni_not_running"
        echo ""
        echo "  Impact on Namespace Termination:"
        echo "    - CNI issues can prevent pod network cleanup"
        echo "    - Pods stuck in Terminating may block namespace deletion"
        echo "    - Review: cni-unhealthy-pods.txt, cni-terminating-pods.txt"
    else
        echo "  ✓ CNI pods appear healthy"
    fi
    
else
    echo "  ℹ No CNI components found in standard namespaces"
    echo "  Checking all namespaces for CNI pods..."
    kubectl get pods -A | grep -iE "calico|flannel|cilium|weave|canal|kube-router|romana|contiv|network" > "$output_dir/cni-pods-all-namespaces.txt" 2>&1
    if [ -s "$output_dir/cni-pods-all-namespaces.txt" ]; then
        echo "  ✓ Found CNI pods (see cni-pods-all-namespaces.txt)"
    else
        echo "  ⚠ No CNI pods found - This is unusual!"
        echo "  Missing CNI can cause network issues and pod deletion failures"
    fi
fi

# CNI configuration files (if accessible)
echo ""
echo "Checking for CNI configuration..."
cni_configmaps=$(kubectl get configmaps -n kube-system 2>/dev/null | grep -iE "cni|calico|flannel|cilium" | awk '{print $1}')
if [ -n "$cni_configmaps" ]; then
    echo "$cni_configmaps" | while read cm; do
        kubectl get configmap "$cm" -n kube-system -o yaml > "$output_dir/cni-configmap-kube-system-${cm}.yaml" 2>&1
    done
    echo "  ✓ CNI ConfigMaps found in kube-system"
fi

# Network-related events
echo "Collecting network-related events..."
kubectl get events -A --sort-by='.lastTimestamp' 2>/dev/null | \
    grep -iE "network|cni|calico|flannel|cilium|weave|pod.*network|network.*error" | \
    tail -100 > "$output_dir/network-events.txt" 2>&1
echo "  ✓ Network events"

# Ingress
echo ""
echo "=========================================="
echo "16. Ingress"
echo "=========================================="
echo ""

kubectl get ingress -A > "$output_dir/ingress.txt" 2>&1
echo "  ✓ Ingress resources"

# ConfigMaps and Secrets (summary)
echo ""
echo "=========================================="
echo "17. ConfigMaps and Secrets (summary)"
echo "=========================================="
echo ""

kubectl get configmaps -A > "$output_dir/configmaps.txt" 2>&1
kubectl get secrets -A > "$output_dir/secrets.txt" 2>&1
echo "  ✓ ConfigMaps and Secrets"

# Service Accounts
echo ""
echo "=========================================="
echo "18. Service Accounts"
echo "=========================================="
echo ""

kubectl get serviceaccounts -A > "$output_dir/service-accounts.txt" 2>&1
echo "  ✓ Service accounts"

# DaemonSets and Deployments
echo ""
echo "=========================================="
echo "19. Workloads"
echo "=========================================="
echo ""

kubectl get deployments -A > "$output_dir/deployments.txt" 2>&1
kubectl get daemonsets -A > "$output_dir/daemonsets.txt" 2>&1
kubectl get statefulsets -A > "$output_dir/statefulsets.txt" 2>&1
kubectl get jobs -A > "$output_dir/jobs.txt" 2>&1
kubectl get cronjobs -A > "$output_dir/cronjobs.txt" 2>&1
echo "  ✓ Workload resources"

# Storage Classes
echo ""
echo "=========================================="
echo "20. Storage"
echo "=========================================="
echo ""

kubectl get storageclass > "$output_dir/storage-classes.txt" 2>&1
echo "  ✓ Storage classes"

# Metrics (if available)
echo ""
echo "=========================================="
echo "21. Metrics (if available)"
echo "=========================================="
echo ""

if kubectl top nodes &>/dev/null; then
    kubectl top nodes > "$output_dir/node-metrics.txt" 2>&1
    kubectl top pods -A > "$output_dir/pod-metrics.txt" 2>&1
    echo "  ✓ Metrics collected"
else
    echo "  ℹ Metrics server not available"
fi

# Namespace Termination Root Cause Analysis
echo ""
echo "=========================================="
echo "Namespace Termination Root Cause Analysis"
echo "=========================================="
echo ""

echo "Analyzing why namespaces (including newly created ones) are stuck in Terminating..."
echo ""

# Check 1: APIServices
unavailable_apis_count=$(cat "$output_dir/unavailable-apiservices.txt" 2>/dev/null | grep -v "^NAME" | wc -l | tr -d ' ')
if [ "$unavailable_apis_count" -gt 0 ]; then
    echo "🔴 ROOT CAUSE #1: Unavailable APIServices ($unavailable_apis_count found)"
    echo "   - Blocks resource enumeration during namespace deletion"
    echo "   - Affects ALL namespace deletions cluster-wide"
    echo "   - Most common cause of namespace termination issues"
    echo "   Fix: Delete broken APIServices (see unavailable-apiservices.txt)"
    echo ""
fi

# Check 2: CNI Issues
if [ -f "$output_dir/cni-unhealthy-pods.txt" ] && [ -s "$output_dir/cni-unhealthy-pods.txt" ]; then
    unhealthy_count=$(cat "$output_dir/cni-unhealthy-pods.txt" | wc -l | tr -d ' ')
    echo "🔴 ROOT CAUSE #2: CNI Health Issues ($unhealthy_count unhealthy pod(s))"
    echo "   - CNI pods crashing/not running prevent network cleanup"
    echo "   - Pods can't be deleted if CNI can't clean up network resources"
    echo "   - This blocks namespace deletion"
    echo "   Fix: Restart/fix CNI pods (see cni-unhealthy-pods.txt)"
    echo ""
fi

# Check 3: Pods stuck in Terminating
if [ -f "$output_dir/cni-terminating-pods.txt" ] && [ -s "$output_dir/cni-terminating-pods.txt" ]; then
    terminating_count=$(cat "$output_dir/cni-terminating-pods.txt" | wc -l | tr -d ' ')
    echo "🟠 SYMPTOM: Pods Stuck in Terminating ($terminating_count pod(s))"
    echo "   - Pods can't be deleted, blocking namespace cleanup"
    echo "   - Often caused by CNI issues or finalizers"
    echo "   Fix: Force delete pods or fix CNI issues"
    echo ""
fi

# Check 4: Stuck namespaces
stuck_ns_count=$(cat "$output_dir/stuck-namespaces.txt" 2>/dev/null | wc -l | tr -d ' ')
if [ "$stuck_ns_count" -gt 0 ]; then
    echo "🟠 SYMPTOM: Namespaces Stuck ($stuck_ns_count namespace(s))"
    echo "   - Namespaces waiting for resources to be cleaned up"
    echo "   - Usually caused by APIService or CNI issues"
    echo ""
fi

# Summary of findings
echo "=========================================="
echo "Analysis Summary"
echo "=========================================="
if [ "$unavailable_apis_count" -gt 0 ]; then
    echo "Primary Issue: Unavailable APIServices (blocks ALL namespace deletions)"
    echo "  → This is the most likely cause of your issue"
elif [ -f "$output_dir/cni-unhealthy-pods.txt" ] && [ -s "$output_dir/cni-unhealthy-pods.txt" ]; then
    echo "Primary Issue: CNI Health Problems (blocks pod/namespace cleanup)"
    echo "  → CNI issues can prevent namespace deletion"
else
    echo "No obvious root cause found in APIServices or CNI"
    echo "  → Review master component logs from collect-podman-logs.sh"
    echo "  → Check for webhook issues or other blockers"
fi
echo ""

# Create summary
echo "=========================================="
echo "Creating Summary"
echo "=========================================="
echo ""

cat > "$output_dir/SUMMARY.txt" <<EOF
Kubernetes Cluster Information Collection Summary
================================================

Collection Date: $(date)
Kubeconfig: $kubeconfig
Cluster: $(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>/dev/null || echo "Unknown")

⚠️  IMPORTANT: This collection was READ-ONLY
   - Only kubectl get/describe/logs commands were used
   - No resources were deleted, modified, or changed
   - Safe for production use

Critical Findings:
EOF

# Add critical findings
if [ -f "$output_dir/unavailable-apiservices.txt" ]; then
    unavailable_count=$(cat "$output_dir/unavailable-apiservices.txt" | grep -v "^NAME" | wc -l | tr -d ' ')
    if [ "$unavailable_count" -gt 0 ]; then
        echo "🔴 Unavailable APIServices: $unavailable_count" >> "$output_dir/SUMMARY.txt"
        cat "$output_dir/unavailable-apiservices.txt" | grep -v "^NAME" | awk '{print "  - " $1}' >> "$output_dir/SUMMARY.txt"
    fi
fi

if [ -f "$output_dir/stuck-namespaces.txt" ]; then
    stuck_count=$(cat "$output_dir/stuck-namespaces.txt" | wc -l | tr -d ' ')
    if [ "$stuck_count" -gt 0 ]; then
        echo "" >> "$output_dir/SUMMARY.txt"
        echo "🔴 Stuck Namespaces: $stuck_count" >> "$output_dir/SUMMARY.txt"
        cat "$output_dir/stuck-namespaces.txt" | awk '{print "  - " $1}' >> "$output_dir/SUMMARY.txt"
    fi
fi

cat >> "$output_dir/SUMMARY.txt" <<EOF

Files Collected:
- apiservices.yaml / unavailable-apiservices.txt (APIService status)
- webhooks.yaml (Webhook configurations)
- namespaces.yaml / stuck-namespaces.txt (Namespace status)
- nodes.yaml / nodes-list.txt (Node information)
- kube-system-pods.txt (System pods)
- pod-*.log (Pod logs from kube-system)
- all-pods.txt (All pods)
- recent-events.txt / warning-events.txt (Events)
- persistent-volumes.txt / persistent-volume-claims.txt (Storage)
- services.txt / endpoints.txt (Services)
- custom-resource-definitions.txt (CRDs)
- cluster-roles.txt / cluster-role-bindings.txt (RBAC)
- deployments.txt / daemonsets.txt / statefulsets.txt (Workloads)
- CNI Information:
  - cni-pods-*.txt (CNI pods by namespace)
  - cni-pod-*.log (CNI pod logs)
  - cni-daemonsets-*.txt (CNI DaemonSets)
  - cni-deployments-*.txt (CNI Deployments)
  - cni-configmaps-*.txt / cni-configmap-*.yaml (CNI ConfigMaps)
  - cni-services-*.txt (CNI Services)
  - calico-*.txt / calico-*.yaml (Calico-specific resources)
  - cilium-*.txt (Cilium-specific resources)
  - network-events.txt (Network-related events)
- And more...

Key Files for Namespace Termination Issues:
1. unavailable-apiservices.txt - Broken APIServices (MOST IMPORTANT)
2. stuck-namespaces.txt - Namespaces stuck in Terminating
3. apiservices.yaml - Full APIService details
4. webhooks.yaml - Webhook configurations
5. recent-events.txt - Recent cluster events
6. pod-kube-system-*.log - Pod logs from kube-system
7. CNI Analysis:
   - cni-detected.txt - Which CNI is installed
   - cni-unhealthy-pods.txt - CNI pods with issues
   - cni-terminating-pods.txt - Pods stuck in Terminating (CNI-related)
   - cni-network-errors.txt - Network error events
   - cni-daemonset-issues.txt - CNI DaemonSet problems

CNI and Namespace Termination Analysis:
EOF

# Add CNI analysis to summary
if [ -f "$output_dir/cni-detected.txt" ]; then
    detected_cni=$(cat "$output_dir/cni-detected.txt" 2>/dev/null)
    echo "  Installed CNI: $detected_cni" >> "$output_dir/SUMMARY.txt"
    
    if [ -f "$output_dir/cni-unhealthy-pods.txt" ] && [ -s "$output_dir/cni-unhealthy-pods.txt" ]; then
        unhealthy_count=$(cat "$output_dir/cni-unhealthy-pods.txt" | wc -l | tr -d ' ')
        echo "  🔴 CNI Health Issues: $unhealthy_count unhealthy pod(s)" >> "$output_dir/SUMMARY.txt"
        echo "     This can prevent pod network cleanup during namespace deletion" >> "$output_dir/SUMMARY.txt"
    fi
    
    if [ -f "$output_dir/cni-terminating-pods.txt" ] && [ -s "$output_dir/cni-terminating-pods.txt" ]; then
        terminating_count=$(cat "$output_dir/cni-terminating-pods.txt" | wc -l | tr -d ' ')
        echo "  🔴 Pods Stuck in Terminating: $terminating_count pod(s)" >> "$output_dir/SUMMARY.txt"
        echo "     CNI issues may be preventing pod cleanup" >> "$output_dir/SUMMARY.txt"
    fi
fi

cat >> "$output_dir/SUMMARY.txt" <<EOF

How CNI Issues Cause Namespace Termination Problems:
1. CNI pods crash/restart → Network cleanup fails → Pods can't be deleted
2. CNI DaemonSet not ready → Network not available → Pod deletion hangs
3. Network errors during cleanup → Pods stuck in Terminating → Namespace stuck
4. CNI finalizers on network resources → Resources can't be cleaned up

Note: Master component logs (apiserver, controller-manager, etcd, scheduler)
      should be collected using collect-podman-logs.sh on each node.

Next Steps:
1. Review unavailable-apiservices.txt - This is usually the root cause
2. Review stuck-namespaces.txt - List of affected namespaces
3. Review pod logs for errors
4. Run collect-podman-logs.sh on each node for master component logs
5. Run: ./diagnose-terminating-namespaces.sh $kubeconfig
EOF

echo "  ✓ Summary created"

echo ""
echo "=========================================="
echo "Collection Complete"
echo "=========================================="
echo ""
echo "✓ Collection finished successfully"
echo "✓ No resources were modified or deleted"
echo "✓ All operations were read-only (kubectl get commands only)"
echo ""
echo "Cluster information saved to: $output_dir"
echo ""
echo "Key files to review for namespace termination issues:"
echo "  1. unavailable-apiservices.txt - Broken APIServices (CRITICAL)"
echo "  2. stuck-namespaces.txt - Stuck namespaces"
echo "  3. apiservices.yaml - Full APIService details"
echo "  4. recent-events.txt - Recent cluster events"
echo "  5. CNI Analysis:"
echo "     - cni-detected.txt - Which CNI is installed"
echo "     - cni-unhealthy-pods.txt - CNI pods with issues"
echo "     - cni-terminating-pods.txt - Pods stuck (CNI-related)"
echo "     - cni-network-errors.txt - Network error events"
echo ""
echo "CNI Impact on Namespace Termination:"
if [ -f "$output_dir/cni-detected.txt" ]; then
    detected_cni=$(cat "$output_dir/cni-detected.txt" 2>/dev/null)
    echo "  Installed CNI: $detected_cni"
    
    if [ -f "$output_dir/cni-unhealthy-pods.txt" ] && [ -s "$output_dir/cni-unhealthy-pods.txt" ]; then
        echo "  🔴 CNI Health Issues Found - May be blocking namespace deletion"
        echo "     Review: cni-unhealthy-pods.txt"
    fi
    
    if [ -f "$output_dir/cni-terminating-pods.txt" ] && [ -s "$output_dir/cni-terminating-pods.txt" ]; then
        terminating_count=$(cat "$output_dir/cni-terminating-pods.txt" | wc -l | tr -d ' ')
        echo "  🔴 $terminating_count pod(s) stuck in Terminating (CNI may be blocking cleanup)"
        echo "     Review: cni-terminating-pods.txt"
    fi
fi
echo ""
echo "To collect master component logs, run on each node:"
echo "  ./collect-podman-logs.sh"
echo ""
