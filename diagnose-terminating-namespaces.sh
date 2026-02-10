#!/bin/bash

# Diagnostic Script for Namespaces Stuck in Terminating State
# This script identifies the root cause of stuck namespace deletions

if [ $# -lt 1 ]; then
    echo "Usage: $0 kubeconfig [namespace]"
    echo ""
    echo "* kubeconfig: Absolute path of kubeconfig file for the cluster"
    echo "* namespace: (Optional) Specific namespace to diagnose. If not provided, checks all Terminating namespaces"
    echo ""
    echo "Eg: $0 /home/user/.kube/config"
    echo "Eg: $0 /home/user/.kube/config kyverno"
    exit 1
fi

kubeconfig=$1
target_ns=$2

echo "=========================================="
echo "Namespace Termination Diagnostic Tool"
echo "=========================================="
echo ""

# Function to check if namespace exists and is Terminating
check_namespace() {
    local ns=$1
    if ! kubectl --kubeconfig=$kubeconfig get ns "$ns" &>/dev/null; then
        return 1
    fi
    local status=$(kubectl --kubeconfig=$kubeconfig get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$status" = "Terminating" ]
}

# Function to get namespace finalizers
get_finalizers() {
    local ns=$1
    kubectl --kubeconfig=$kubeconfig get ns "$ns" -o jsonpath='{.spec.finalizers[*]}' 2>/dev/null
}

# Function to check for resources in namespace
check_resources() {
    local ns=$1
    echo "  Checking resources in namespace '$ns':"
    
    # Check for pods
    pod_count=$(kubectl --kubeconfig=$kubeconfig get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
    if [ "$pod_count" -gt 0 ]; then
        echo "    ⚠ Found $pod_count pod(s) still present:"
        kubectl --kubeconfig=$kubeconfig get pods -n "$ns" --no-headers 2>/dev/null | head -5 | awk '{print "      - " $1 " (" $3 ")"}'
        [ "$pod_count" -gt 5 ] && echo "      ... and $((pod_count - 5)) more"
    fi
    
    # Check for PVCs
    pvc_count=$(kubectl --kubeconfig=$kubeconfig get pvc -n "$ns" --no-headers 2>/dev/null | wc -l)
    if [ "$pvc_count" -gt 0 ]; then
        echo "    ⚠ Found $pvc_count PVC(s) still present:"
        kubectl --kubeconfig=$kubeconfig get pvc -n "$ns" --no-headers 2>/dev/null | awk '{print "      - " $1}'
    fi
    
    # Check for services
    svc_count=$(kubectl --kubeconfig=$kubeconfig get svc -n "$ns" --no-headers 2>/dev/null | wc -l)
    if [ "$svc_count" -gt 0 ]; then
        echo "    ⚠ Found $svc_count service(s) still present"
    fi
    
    # Check for deployments
    deploy_count=$(kubectl --kubeconfig=$kubeconfig get deployments -n "$ns" --no-headers 2>/dev/null | wc -l)
    if [ "$deploy_count" -gt 0 ]; then
        echo "    ⚠ Found $deploy_count deployment(s) still present"
    fi
    
    # Check for statefulsets
    sts_count=$(kubectl --kubeconfig=$kubeconfig get statefulsets -n "$ns" --no-headers 2>/dev/null | wc -l)
    if [ "$sts_count" -gt 0 ]; then
        echo "    ⚠ Found $sts_count statefulset(s) still present"
    fi
    
    # Check for ConfigMaps
    cm_count=$(kubectl --kubeconfig=$kubeconfig get configmaps -n "$ns" --no-headers 2>/dev/null | wc -l)
    if [ "$cm_count" -gt 0 ]; then
        echo "    ⚠ Found $cm_count ConfigMap(s) still present:"
        kubectl --kubeconfig=$kubeconfig get configmaps -n "$ns" --no-headers 2>/dev/null | awk '{print "      - " $1}'
    fi
    
    # Check for ServiceAccounts
    sa_count=$(kubectl --kubeconfig=$kubeconfig get serviceaccounts -n "$ns" --no-headers 2>/dev/null | wc -l)
    if [ "$sa_count" -gt 0 ]; then
        echo "    ⚠ Found $sa_count ServiceAccount(s) still present:"
        kubectl --kubeconfig=$kubeconfig get serviceaccounts -n "$ns" --no-headers 2>/dev/null | awk '{print "      - " $1}'
    fi
    
    # Check for Secrets
    secret_count=$(kubectl --kubeconfig=$kubeconfig get secrets -n "$ns" --no-headers 2>/dev/null | wc -l)
    if [ "$secret_count" -gt 0 ]; then
        echo "    ⚠ Found $secret_count Secret(s) still present:"
        kubectl --kubeconfig=$kubeconfig get secrets -n "$ns" --no-headers 2>/dev/null | head -5 | awk '{print "      - " $1}'
        [ "$secret_count" -gt 5 ] && echo "      ... and $((secret_count - 5)) more"
    fi
    
    # Check for CRDs with instances
    echo "    Checking for Custom Resources..."
    crd_resources=$(kubectl --kubeconfig=$kubeconfig api-resources --namespaced=true --verbs=list -o name 2>/dev/null | grep -v "^events" | grep -v "^configmaps" | grep -v "^secrets" | grep -v "^serviceaccounts")
    for crd in $crd_resources; do
        count=$(kubectl --kubeconfig=$kubeconfig get "$crd" -n "$ns" --no-headers 2>/dev/null | wc -l)
        if [ "$count" -gt 0 ]; then
            echo "    ⚠ Found $count instance(s) of $crd:"
            kubectl --kubeconfig=$kubeconfig get "$crd" -n "$ns" --no-headers 2>/dev/null | head -3 | awk '{print "      - " $1}'
            [ "$count" -gt 3 ] && echo "      ... and $((count - 3)) more"
        fi
    done
    
    # Total resource count
    total=$(kubectl --kubeconfig=$kubeconfig api-resources --verbs=list --namespaced -o name 2>/dev/null | \
        xargs -I {} sh -c "kubectl --kubeconfig=$kubeconfig get {} -n $ns --no-headers 2>/dev/null | wc -l" | \
        awk '{sum+=$1} END {print sum}')
    
    if [ "$total" -gt 0 ]; then
        echo "    ⚠ Total resources remaining: $total"
    else
        echo "    ✓ No resources remaining in namespace"
    fi
}

# Function to check APIServices
check_apiservices() {
    echo ""
    echo "  Checking for unavailable APIServices (common blocker):"
    unavailable=$(kubectl --kubeconfig=$kubeconfig get apiservices -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.conditions[]? | select(.type=="Available" and .status=="False")) | .metadata.name' 2>/dev/null)
    
    if [ -n "$unavailable" ]; then
        echo "    🔴 Found unavailable APIServices (these block namespace deletion):"
        echo "$unavailable" | while read api; do
            reason=$(kubectl --kubeconfig=$kubeconfig get apiservice "$api" -o jsonpath='{.status.conditions[?(@.type=="Available")].reason}' 2>/dev/null)
            message=$(kubectl --kubeconfig=$kubeconfig get apiservice "$api" -o jsonpath='{.status.conditions[?(@.type=="Available")].message}' 2>/dev/null)
            echo "      - $api"
            echo "        Reason: $reason"
            echo "        Message: $message"
        done
    else
        echo "    ✓ All APIServices are available"
    fi
}

# Function to check webhooks
check_webhooks() {
    echo ""
    echo "  Checking for webhooks that might block deletion:"
    
    # Check mutating webhooks
    mutating=$(kubectl --kubeconfig=$kubeconfig get mutatingwebhookconfigurations -o json 2>/dev/null | \
        jq -r '.items[] | select(.webhooks[]?.namespaceSelector) | .metadata.name' 2>/dev/null)
    
    # Check validating webhooks
    validating=$(kubectl --kubeconfig=$kubeconfig get validatingwebhookconfigurations -o json 2>/dev/null | \
        jq -r '.items[] | select(.webhooks[]?.namespaceSelector) | .metadata.name' 2>/dev/null)
    
    if [ -n "$mutating" ] || [ -n "$validating" ]; then
        echo "    ⚠ Found webhooks with namespace selectors:"
        [ -n "$mutating" ] && echo "$mutating" | while read wh; do echo "      - MutatingWebhook: $wh"; done
        [ -n "$validating" ] && echo "$validating" | while read wh; do echo "      - ValidatingWebhook: $wh"; done
    else
        echo "    ✓ No problematic webhooks found"
    fi
}

# Function to diagnose a specific namespace
diagnose_namespace() {
    local ns=$1
    echo ""
    echo "=========================================="
    echo "Diagnosing namespace: $ns"
    echo "=========================================="
    
    # Check if namespace exists
    if ! kubectl --kubeconfig=$kubeconfig get ns "$ns" &>/dev/null; then
        echo "❌ Namespace '$ns' does not exist"
        return 1
    fi
    
    # Check status
    status=$(kubectl --kubeconfig=$kubeconfig get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)
    echo "Status: $status"
    
    if [ "$status" != "Terminating" ]; then
        echo "ℹ Namespace is not in Terminating state"
        return 0
    fi
    
    # Get deletion timestamp
    deletion_time=$(kubectl --kubeconfig=$kubeconfig get ns "$ns" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)
    echo "Deletion requested at: $deletion_time"
    
    # Check finalizers
    echo ""
    echo "1. Checking Finalizers:"
    finalizers=$(get_finalizers "$ns")
    if [ -n "$finalizers" ]; then
        echo "  🔴 Found finalizers blocking deletion:"
        echo "$finalizers" | tr ' ' '\n' | while read finalizer; do
            echo "    - $finalizer"
        done
    else
        echo "  ✓ No finalizers found"
    fi
    
    # Check resources
    echo ""
    echo "2. Checking Resources:"
    check_resources "$ns"
    
    # Check APIServices
    echo ""
    echo "3. Checking APIServices:"
    check_apiservices
    
    # Check webhooks
    echo ""
    echo "4. Checking Webhooks:"
    check_webhooks
    
    # Check for specific known issues
    echo ""
    echo "5. Known Issue Checks:"
    
    # Check for Kyverno APIServices
    kyverno_apis=$(kubectl --kubeconfig=$kubeconfig get apiservice 2>/dev/null | grep -E "kyverno|wgpolicyk8s|openreports" | grep -v "True" | wc -l)
    if [ "$kyverno_apis" -gt 0 ]; then
        echo "  🔴 Kyverno APIServices are unavailable (common blocker):"
        kubectl --kubeconfig=$kubeconfig get apiservice 2>/dev/null | grep -E "kyverno|wgpolicyk8s|openreports" | grep -v "True" | awk '{print "    - " $1 " (" $2 ")"}'
    fi
    
    # Summary and recommendations
    echo ""
    echo "=========================================="
    echo "Summary & Recommendations:"
    echo "=========================================="
    
    # Check for remaining resources
    pod_count=$(kubectl --kubeconfig=$kubeconfig get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
    cm_count=$(kubectl --kubeconfig=$kubeconfig get configmaps -n "$ns" --no-headers 2>/dev/null | wc -l)
    sa_count=$(kubectl --kubeconfig=$kubeconfig get serviceaccounts -n "$ns" --no-headers 2>/dev/null | wc -l)
    secret_count=$(kubectl --kubeconfig=$kubeconfig get secrets -n "$ns" --no-headers 2>/dev/null | wc -l)
    pvc_count=$(kubectl --kubeconfig=$kubeconfig get pvc -n "$ns" --no-headers 2>/dev/null | wc -l)
    
    total_resources=$((pod_count + cm_count + sa_count + secret_count + pvc_count))
    
    if [ "$total_resources" -gt 0 ]; then
        echo "🔴 RESOURCES BLOCKING: $total_resources resource(s) still present"
        echo ""
        echo "Step 1: Force delete remaining resources:"
        echo ""
        
        if [ "$pod_count" -gt 0 ]; then
            echo "  # Force delete pods:"
            echo "  kubectl --kubeconfig=$kubeconfig delete pods --all -n $ns --force --grace-period=0"
        fi
        
        if [ "$pvc_count" -gt 0 ]; then
            echo "  # Delete PVCs:"
            echo "  kubectl --kubeconfig=$kubeconfig delete pvc --all -n $ns"
        fi
        
        if [ "$cm_count" -gt 0 ]; then
            echo "  # Delete ConfigMaps:"
            echo "  kubectl --kubeconfig=$kubeconfig delete configmaps --all -n $ns"
        fi
        
        if [ "$sa_count" -gt 0 ]; then
            echo "  # Delete ServiceAccounts:"
            echo "  kubectl --kubeconfig=$kubeconfig delete serviceaccounts --all -n $ns"
        fi
        
        if [ "$secret_count" -gt 0 ]; then
            echo "  # Delete Secrets (be careful with this):"
            echo "  kubectl --kubeconfig=$kubeconfig delete secrets --all -n $ns"
        fi
        
        echo ""
        echo "  # Or delete ALL resources at once:"
        echo "  kubectl --kubeconfig=$kubeconfig delete all --all -n $ns --force --grace-period=0"
        echo "  kubectl --kubeconfig=$kubeconfig delete configmaps,secrets,serviceaccounts --all -n $ns"
        echo ""
    fi
    
    finalizers=$(get_finalizers "$ns")
    if [ -n "$finalizers" ]; then
        echo "🔴 FINALIZER BLOCKING: Finalizers are preventing deletion"
        echo ""
        echo "Step 2: Clear finalizers (run this AFTER deleting resources):"
        echo "  kubectl --kubeconfig=$kubeconfig get ns $ns -o json | jq '.spec.finalizers = []' | kubectl --kubeconfig=$kubeconfig replace --raw \"/api/v1/namespaces/$ns/finalize\" -f -"
        echo ""
    fi
    
    unavailable_apis=$(kubectl --kubeconfig=$kubeconfig get apiservices -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.conditions[]? | select(.type=="Available" and .status=="False")) | .metadata.name' 2>/dev/null | wc -l)
    if [ "$unavailable_apis" -gt 0 ]; then
        echo "🔴 APISERVICE BLOCKING: Unavailable APIServices are blocking deletion"
        echo ""
        echo "Step 3: Delete the broken APIServices:"
        kubectl --kubeconfig=$kubeconfig get apiservices -o json 2>/dev/null | \
            jq -r '.items[] | select(.status.conditions[]? | select(.type=="Available" and .status=="False")) | "  kubectl --kubeconfig='$kubeconfig' delete apiservice " + .metadata.name' 2>/dev/null
        echo ""
    fi
    
    if [ "$total_resources" -gt 0 ] || [ -n "$finalizers" ]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Quick Fix (run all commands):"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "# 1. Delete all resources"
        echo "kubectl --kubeconfig=$kubeconfig delete all --all -n $ns --force --grace-period=0"
        echo "kubectl --kubeconfig=$kubeconfig delete configmaps,secrets,serviceaccounts,pvc --all -n $ns"
        echo ""
        echo "# 2. Clear finalizers"
        echo "kubectl --kubeconfig=$kubeconfig get ns $ns -o json | jq '.spec.finalizers = []' | kubectl --kubeconfig=$kubeconfig replace --raw \"/api/v1/namespaces/$ns/finalize\" -f -"
        echo ""
    fi
    
    echo "For detailed resource list, run:"
    echo "  kubectl --kubeconfig=$kubeconfig get all -n $ns"
    echo "  kubectl --kubeconfig=$kubeconfig api-resources --verbs=list --namespaced -o name | xargs -I {} kubectl --kubeconfig=$kubeconfig get {} -n $ns"
}

# Main execution
if [ -n "$target_ns" ]; then
    # Diagnose specific namespace
    diagnose_namespace "$target_ns"
else
    # Find all Terminating namespaces and diagnose each
    echo "Scanning for namespaces stuck in Terminating state..."
    echo ""
    
    terminating_ns=$(kubectl --kubeconfig=$kubeconfig get ns -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.phase=="Terminating") | .metadata.name' 2>/dev/null)
    
    if [ -z "$terminating_ns" ]; then
        echo "✓ No namespaces found in Terminating state"
        exit 0
    fi
    
    count=$(echo "$terminating_ns" | wc -l | tr -d ' ')
    echo "Found $count namespace(s) stuck in Terminating state:"
    echo "$terminating_ns" | while read ns; do
        echo "  - $ns"
    done
    
    echo ""
    echo "Running full diagnostic on each namespace..."
    echo ""
    
    echo "$terminating_ns" | while read ns; do
        diagnose_namespace "$ns"
        echo ""
    done
    
    echo ""
    echo "=========================================="
    echo "Quick Summary"
    echo "=========================================="
    echo ""
    echo "To clear finalizers on all stuck namespaces:"
    echo "$terminating_ns" | while read ns; do
        echo "  kubectl --kubeconfig=$kubeconfig get ns $ns -o json | jq '.spec.finalizers = []' | kubectl --kubeconfig=$kubeconfig replace --raw \"/api/v1/namespaces/$ns/finalize\" -f -"
    done
fi
