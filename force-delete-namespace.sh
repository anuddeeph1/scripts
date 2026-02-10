#!/bin/bash

# Force Delete Namespace Script
# This script forcefully deletes a namespace stuck in Terminating state

if [ $# -lt 2 ]; then
    echo "Usage: $0 kubeconfig namespace"
    echo ""
    echo "* kubeconfig: Absolute path of kubeconfig file for the cluster"
    echo "* namespace: Name of the namespace to force delete"
    echo ""
    echo "Eg: $0 /home/user/.kube/config test1"
    exit 1
fi

kubeconfig=$1
namespace=$2

echo "Force deleting namespace: $namespace"
echo "===================================="
echo ""

# Check if namespace exists
if ! kubectl --kubeconfig=$kubeconfig get ns "$namespace" &>/dev/null; then
    echo "❌ Namespace '$namespace' does not exist"
    exit 1
fi

# Check if namespace is in Terminating state
status=$(kubectl --kubeconfig=$kubeconfig get ns "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
if [ "$status" != "Terminating" ]; then
    echo "ℹ Namespace is not in Terminating state (current: $status)"
    echo "Attempting normal deletion..."
    kubectl --kubeconfig=$kubeconfig delete ns "$namespace"
    exit 0
fi

echo "Namespace is stuck in Terminating state"
echo ""

# Step 1: Delete all resources
echo "Step 1: Deleting all resources in namespace..."
kubectl --kubeconfig=$kubeconfig delete all --all -n "$namespace" --force --grace-period=0 2>/dev/null || true
kubectl --kubeconfig=$kubeconfig delete configmaps,secrets,serviceaccounts --all -n "$namespace" 2>/dev/null || true
kubectl --kubeconfig=$kubeconfig delete pvc --all -n "$namespace" 2>/dev/null || true

# Wait a moment
sleep 2

# Step 2: Check for remaining resources
echo ""
echo "Step 2: Checking for remaining resources..."
remaining=$(kubectl --kubeconfig=$kubeconfig api-resources --verbs=list --namespaced -o name 2>/dev/null | \
    xargs -I {} sh -c "kubectl --kubeconfig=$kubeconfig get {} -n $namespace --no-headers 2>/dev/null | wc -l" | \
    awk '{sum+=$1} END {print sum}')

if [ "$remaining" -gt 0 ]; then
    echo "⚠ Still found $remaining resource(s) remaining"
    echo "Attempting to delete specific resources..."
    
    # Try to delete common resources
    for resource in configmaps secrets serviceaccounts roles rolebindings networkpolicies; do
        kubectl --kubeconfig=$kubeconfig delete "$resource" --all -n "$namespace" --force --grace-period=0 2>/dev/null || true
    done
else
    echo "✓ All resources deleted"
fi

# Step 3: Clear finalizers
echo ""
echo "Step 3: Clearing finalizers..."
kubectl --kubeconfig=$kubeconfig get ns "$namespace" -o json | \
    jq '.spec.finalizers = []' | \
    kubectl --kubeconfig=$kubeconfig replace --raw "/api/v1/namespaces/$namespace/finalize" -f - 2>/dev/null

if [ $? -eq 0 ]; then
    echo "✓ Finalizers cleared"
else
    echo "⚠ Failed to clear finalizers via direct API, trying alternative method..."
    
    # Alternative method using kubectl proxy
    kubectl --kubeconfig=$kubeconfig get namespace "$namespace" -o json | \
        jq '.spec = {"finalizers":[]}' > /tmp/tmp-${namespace}.json
    
    kubectl --kubeconfig=$kubeconfig proxy > /dev/null 2>&1 &
    PROXY_PID=$!
    sleep 3
    
    curl -H "Content-Type: application/json" -X PUT --data-binary @/tmp/tmp-${namespace}.json \
        http://localhost:8001/api/v1/namespaces/$namespace/finalize 2>/dev/null || true
    
    kill $PROXY_PID 2>/dev/null || true
    rm -f /tmp/tmp-${namespace}.json
    echo "✓ Finalizers cleared (alternative method)"
fi

# Wait and verify
echo ""
echo "Step 4: Verifying deletion..."
sleep 3

if kubectl --kubeconfig=$kubeconfig get ns "$namespace" &>/dev/null; then
    status=$(kubectl --kubeconfig=$kubeconfig get ns "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$status" = "Terminating" ]; then
        echo "⚠ Namespace still in Terminating state"
        echo ""
        echo "Remaining resources:"
        kubectl --kubeconfig=$kubeconfig api-resources --verbs=list --namespaced -o name 2>/dev/null | \
            xargs -I {} sh -c "count=\$(kubectl --kubeconfig=$kubeconfig get {} -n $namespace --no-headers 2>/dev/null | wc -l); [ \$count -gt 0 ] && echo \"  {}: \$count\"" || echo "  None"
        echo ""
        echo "Run the diagnostic script for detailed analysis:"
        echo "  ./diagnose-terminating-namespaces.sh $kubeconfig $namespace"
    else
        echo "✓ Namespace status: $status"
    fi
else
    echo "✓ Namespace '$namespace' has been deleted successfully"
fi
