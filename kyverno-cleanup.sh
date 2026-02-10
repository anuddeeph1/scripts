#!/bin/bash

# Kyverno Complete Cleanup Script
# This script removes all Kyverno resources including broken APIServices

set -e

echo "=== Step 1: Delete Broken APIServices (CRITICAL) ==="
kubectl delete apiservice v1.reports.kyverno.io --ignore-not-found=true
kubectl delete apiservice v1alpha1.openreports.io --ignore-not-found=true
kubectl delete apiservice v1alpha2.wgpolicyk8s.io --ignore-not-found=true
echo "✓ APIServices deleted"

echo ""
echo "=== Step 2: Delete any remaining Kyverno CRDs ==="
kubectl delete crd -l app.kubernetes.io/name=kyverno --ignore-not-found=true
kubectl delete crd policies.kyverno.io --ignore-not-found=true
kubectl delete crd clusterpolicies.kyverno.io --ignore-not-found=true
kubectl delete crd policyreports.wgpolicyk8s.io --ignore-not-found=true
kubectl delete crd clusterpolicyreports.wgpolicyk8s.io --ignore-not-found=true
kubectl delete crd reports.wgpolicyk8s.io --ignore-not-found=true
kubectl delete crd updaterequests.kyverno.io --ignore-not-found=true
kubectl delete crd exceptions.kyverno.io --ignore-not-found=true
kubectl delete crd cleanuppolicies.kyverno.io --ignore-not-found=true
kubectl delete crd clustercleanuppolicies.kyverno.io --ignore-not-found=true
echo "✓ CRDs deleted"

echo ""
echo "=== Step 3: Clear finalizers on stuck namespaces ==="

# Function to clear namespace finalizers
clear_ns_finalizers() {
    local ns=$1
    echo "Clearing finalizers for namespace: $ns"
    kubectl get ns "$ns" -o json | \
        jq '.spec.finalizers = []' | \
        kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || echo "  ⚠ Failed to clear finalizers for $ns"
}

# List of stuck namespaces from your output
STUCK_NAMESPACES=(
    "kyverno"
    "delete-ns"
    "migration-test17"
    "prabhu-test"
    "test"
    "test1"
    "test2"
    "test3"
    "test4"
)

for ns in "${STUCK_NAMESPACES[@]}"; do
    if kubectl get ns "$ns" &>/dev/null; then
        clear_ns_finalizers "$ns"
    else
        echo "  ℹ Namespace $ns already deleted"
    fi
done

echo ""
echo "=== Step 4: Verify cleanup ==="
echo "Checking for remaining Kyverno APIServices:"
kubectl get apiservices | grep -E "kyverno|wgpolicyk8s|openreports" || echo "  ✓ No Kyverno APIServices found"

echo ""
echo "Checking stuck namespaces:"
kubectl get ns | grep Terminating || echo "  ✓ No namespaces stuck in Terminating"

echo ""
echo "=== Cleanup Complete ==="
echo "If namespaces are still stuck, wait 30 seconds and run:"
echo "  kubectl get ns | grep Terminating"
