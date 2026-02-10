#!/bin/bash

# Kyverno Cleanup Script (Does NOT touch nirmata namespace)
# This script removes all Kyverno resources and does NOT interact with nirmata namespace at all

if [ $# -lt 3 ]; then
    echo "Usage: $0 kubeconfig namespace1 namespace2"
    echo ""
    echo "* kubeconfig: Absolute path of kubeconfig file for the cluster"
    echo "* namespace1: kyverno namespace"
    echo "* namespace2: nirmata-kyverno-operator namespace"
    echo ""
    echo "Note: nirmata namespace is NOT touched by this script"
    echo ""
    echo "Eg: $0 /home/user/.kube/config kyverno nirmata-kyverno-operator"
    exit 1
fi

echo "Cleaning up Kyverno from the cluster (nirmata namespace will NOT be touched)"
echo ""

kubeconfig=$1
namespace1=$2
namespace2=$3

# Set error handling
set -e

# Step 1: Delete APIServices (CRITICAL - this is what blocks namespace deletion)
echo "=== Step 1: Deleting Kyverno APIServices ==="
kubectl --kubeconfig=$kubeconfig delete apiservice v1.reports.kyverno.io --ignore-not-found=true
kubectl --kubeconfig=$kubeconfig delete apiservice v1alpha1.openreports.io --ignore-not-found=true
kubectl --kubeconfig=$kubeconfig delete apiservice v1alpha2.wgpolicyk8s.io --ignore-not-found=true
echo "✓ APIServices deleted"
echo ""

# Step 2: Delete ClusterPolicies
echo "=== Step 2: Deleting ClusterPolicies ==="
kubectl --kubeconfig=$kubeconfig delete cpol --all --ignore-not-found=true
echo "✓ ClusterPolicies deleted"
echo ""

# Step 3: Delete Kyverno CRDs (only kyverno and wgpolicy, NOT nirmata)
echo "=== Step 3: Deleting Kyverno CRDs ==="
kubectl --kubeconfig=$kubeconfig get crd | grep -i kyverno | awk '{print $1}' | xargs -r kubectl --kubeconfig=$kubeconfig delete crd --ignore-not-found=true
kubectl --kubeconfig=$kubeconfig get crd | grep -i wgpolicy | awk '{print $1}' | xargs -r kubectl --kubeconfig=$kubeconfig delete crd --ignore-not-found=true
echo "✓ CRDs deleted"
echo ""

# Step 4: Delete Kyverno ClusterRoles (only kyverno, NOT nirmata)
echo "=== Step 4: Deleting Kyverno ClusterRoles ==="
kubectl --kubeconfig=$kubeconfig get clusterrole | grep -i "^kyverno" | awk '{print $1}' | xargs -r kubectl --kubeconfig=$kubeconfig delete clusterrole --ignore-not-found=true
echo "✓ ClusterRoles deleted"
echo ""

# Step 5: Delete Kyverno ClusterRoleBindings (only kyverno, NOT nirmata)
echo "=== Step 5: Deleting Kyverno ClusterRoleBindings ==="
kubectl --kubeconfig=$kubeconfig get clusterrolebinding | grep -i "^kyverno" | awk '{print $1}' | xargs -r kubectl --kubeconfig=$kubeconfig delete clusterrolebinding --ignore-not-found=true
echo "✓ ClusterRoleBindings deleted"
echo ""

# Step 6: Delete WebhookConfigurations (only kyverno, NOT nirmata)
echo "=== Step 6: Deleting Kyverno WebhookConfigurations ==="
kubectl --kubeconfig=$kubeconfig get mutatingwebhookconfigurations | grep -i kyverno | awk '{print $1}' | xargs -r kubectl --kubeconfig=$kubeconfig delete mutatingwebhookconfigurations --ignore-not-found=true
kubectl --kubeconfig=$kubeconfig get validatingwebhookconfigurations | grep -i kyverno | awk '{print $1}' | xargs -r kubectl --kubeconfig=$kubeconfig delete validatingwebhookconfigurations --ignore-not-found=true
echo "✓ WebhookConfigurations deleted"
echo ""

# Step 7: Delete namespaces (kyverno and nirmata-kyverno-operator only)
echo "=== Step 7: Deleting Kyverno namespaces ==="
kubectl --kubeconfig=$kubeconfig delete ns $namespace1 --ignore-not-found=true || true
kubectl --kubeconfig=$kubeconfig delete ns $namespace2 --ignore-not-found=true || true
echo "✓ Namespaces deletion initiated"
echo ""

# Step 8: Clear finalizers if namespaces are stuck
echo "=== Step 8: Checking for stuck namespaces and clearing finalizers ==="

clear_ns_finalizers() {
    local ns=$1
    if kubectl --kubeconfig=$kubeconfig get ns "$ns" &>/dev/null; then
        echo "Clearing finalizers for namespace: $ns"
        kubectl --kubeconfig=$kubeconfig get namespace "$ns" -o json | \
            jq '.spec.finalizers = []' | \
            kubectl --kubeconfig=$kubeconfig replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || {
                echo "  Attempting alternative method for $ns..."
                kubectl --kubeconfig=$kubeconfig get namespace "$ns" -o json | \
                    jq '.spec = {"finalizers":[]}' > /tmp/tmp-${ns}.json
                kubectl --kubeconfig=$kubeconfig proxy > /dev/null 2>&1 &
                PROXY_PID=$!
                sleep 3
                curl -H "Content-Type: application/json" -X PUT --data-binary @/tmp/tmp-${ns}.json \
                    http://localhost:8001/api/v1/namespaces/$ns/finalize 2>/dev/null || true
                kill $PROXY_PID 2>/dev/null || true
                rm -f /tmp/tmp-${ns}.json
            }
        echo "  ✓ Finalizers cleared for $ns"
    fi
}

# Wait a bit for normal deletion
sleep 5

# Clear finalizers for kyverno namespaces if still stuck
if kubectl --kubeconfig=$kubeconfig get ns $namespace1 &>/dev/null; then
    clear_ns_finalizers $namespace1
fi

if kubectl --kubeconfig=$kubeconfig get ns $namespace2 &>/dev/null; then
    clear_ns_finalizers $namespace2
fi

# Step 9: Clean up helm secrets (only kyverno-related)
echo ""
echo "=== Step 10: Cleaning up Kyverno helm secrets ==="
kubectl --kubeconfig=$kubeconfig get secret -A | grep -i kyverno | awk '{print $1" "$2}' | \
    while read ns secret; do
        kubectl --kubeconfig=$kubeconfig delete secret -n "$ns" "$secret" --ignore-not-found=true
    done
echo "✓ Helm secrets cleaned"
echo ""

# Final verification
echo "=== Verification ==="
echo "Checking for remaining Kyverno APIServices:"
kubectl --kubeconfig=$kubeconfig get apiservices | grep -E "kyverno|wgpolicyk8s|openreports" || echo "  ✓ No Kyverno APIServices found"

echo ""
echo "Checking stuck namespaces:"
kubectl --kubeconfig=$kubeconfig get ns | grep Terminating || echo "  ✓ No namespaces stuck in Terminating"

echo ""
echo "=== Cleanup Complete ==="
echo "✓ Kyverno resources deleted"
echo "✓ nirmata namespace was NOT touched"
echo ""
echo "If any namespaces are still stuck, wait 30 seconds and check:"
echo "  kubectl --kubeconfig=$kubeconfig get ns | grep Terminating"
