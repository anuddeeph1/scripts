#!/bin/bash

# Quick Check Script for Terminating Namespaces
# Provides a fast summary of stuck namespaces and their blockers

if [ $# -lt 1 ]; then
    echo "Usage: $0 kubeconfig"
    echo ""
    echo "* kubeconfig: Absolute path of kubeconfig file for the cluster"
    echo ""
    echo "Eg: $0 /home/user/.kube/config"
    exit 1
fi

kubeconfig=$1

echo "Quick Check: Terminating Namespaces"
echo "===================================="
echo ""

# Find all Terminating namespaces
terminating_ns=$(kubectl --kubeconfig=$kubeconfig get ns -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.phase=="Terminating") | .metadata.name' 2>/dev/null)

if [ -z "$terminating_ns" ]; then
    echo "✓ No namespaces stuck in Terminating state"
    exit 0
fi

count=$(echo "$terminating_ns" | wc -l | tr -d ' ')
echo "Found $count namespace(s) stuck in Terminating:"
echo ""

echo "$terminating_ns" | while read ns; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Namespace: $ns"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Check finalizers
    finalizers=$(kubectl --kubeconfig=$kubeconfig get ns "$ns" -o jsonpath='{.spec.finalizers[*]}' 2>/dev/null)
    if [ -n "$finalizers" ]; then
        echo "🔴 Finalizers: $(echo $finalizers | tr ' ' ',')"
    else
        echo "✓ No finalizers"
    fi
    
    # Check resources
    pod_count=$(kubectl --kubeconfig=$kubeconfig get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
    pvc_count=$(kubectl --kubeconfig=$kubeconfig get pvc -n "$ns" --no-headers 2>/dev/null | wc -l)
    if [ "$pod_count" -gt 0 ] || [ "$pvc_count" -gt 0 ]; then
        echo "🔴 Resources: $pod_count pod(s), $pvc_count PVC(s)"
    else
        echo "✓ No resources remaining"
    fi
    
    # Check for unavailable APIServices
    unavailable_apis=$(kubectl --kubeconfig=$kubeconfig get apiservices -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.conditions[]? | select(.type=="Available" and .status=="False")) | .metadata.name' 2>/dev/null | wc -l)
    if [ "$unavailable_apis" -gt 0 ]; then
        echo "🔴 Unavailable APIServices: $unavailable_apis"
        echo "   (Run full diagnostic for details)"
    else
        echo "✓ All APIServices available"
    fi
    
    echo ""
done

# Check for common blockers
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Common Blockers Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Kyverno APIServices
kyverno_apis=$(kubectl --kubeconfig=$kubeconfig get apiservices 2>/dev/null | \
    grep -E "kyverno|wgpolicyk8s|openreports" | grep -v "True" | wc -l)
if [ "$kyverno_apis" -gt 0 ]; then
    echo "🔴 Kyverno APIServices unavailable: $kyverno_apis"
    echo "   Fix: kubectl delete apiservice v1.reports.kyverno.io v1alpha1.openreports.io v1alpha2.wgpolicyk8s.io"
else
    echo "✓ Kyverno APIServices OK"
fi

echo ""
echo "For detailed diagnosis, run:"
echo "  ./diagnose-terminating-namespaces.sh $kubeconfig"
