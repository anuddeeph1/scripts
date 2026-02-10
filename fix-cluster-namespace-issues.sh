#!/bin/bash

# Cluster-Wide Fix Script for Namespace Termination Issues
# Fixes common cluster-wide problems causing namespaces to get stuck

if [ $# -lt 1 ]; then
    echo "Usage: $0 kubeconfig [--dry-run]"
    echo ""
    echo "* kubeconfig: Absolute path of kubeconfig file for the cluster"
    echo "* --dry-run: (Optional) Show what would be fixed without making changes"
    echo ""
    echo "Eg: $0 /home/user/.kube/config"
    echo "Eg: $0 /home/user/.kube/config --dry-run"
    exit 1
fi

kubeconfig=$1
dry_run=false

if [ "$2" = "--dry-run" ]; then
    dry_run=true
    echo "DRY RUN MODE - No changes will be made"
    echo ""
fi

echo "=========================================="
echo "Cluster-Wide Namespace Fix Tool"
echo "=========================================="
echo ""

# Function to execute command or show what would be done
execute() {
    local cmd=$1
    local description=$2
    
    if [ "$dry_run" = true ]; then
        echo "[DRY RUN] Would execute: $cmd"
        echo "  Description: $description"
    else
        echo "Executing: $description"
        eval "$cmd"
    fi
}

# Step 1: Fix Unavailable APIServices
echo "=========================================="
echo "Step 1: Fixing Unavailable APIServices"
echo "=========================================="
echo ""

unavailable_apis=$(kubectl --kubeconfig=$kubeconfig get apiservices -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.conditions[]? | select(.type=="Available" and .status=="False")) | .metadata.name' 2>/dev/null)

if [ -n "$unavailable_apis" ]; then
    echo "Found unavailable APIServices:"
    echo "$unavailable_apis" | while read api; do
        reason=$(kubectl --kubeconfig=$kubeconfig get apiservice "$api" -o jsonpath='{.status.conditions[?(@.type=="Available")].reason}' 2>/dev/null)
        echo "  - $api (Reason: $reason)"
    done
    echo ""
    
    if [ "$dry_run" = false ]; then
        read -p "Delete these broken APIServices? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo "$unavailable_apis" | while read api; do
                execute "kubectl --kubeconfig=$kubeconfig delete apiservice \"$api\"" "Deleting APIService: $api"
            done
        else
            echo "Skipping APIService deletion"
        fi
    else
        echo "$unavailable_apis" | while read api; do
            execute "kubectl --kubeconfig=$kubeconfig delete apiservice \"$api\"" "Would delete APIService: $api"
        done
    fi
else
    echo "✓ No unavailable APIServices found"
fi

echo ""

# Step 2: Clear finalizers on stuck namespaces
echo "=========================================="
echo "Step 2: Fixing Stuck Namespaces"
echo "=========================================="
echo ""

terminating_ns=$(kubectl --kubeconfig=$kubeconfig get ns -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.phase=="Terminating") | .metadata.name' 2>/dev/null)

if [ -n "$terminating_ns" ]; then
    count=$(echo "$terminating_ns" | wc -l | tr -d ' ')
    echo "Found $count namespace(s) stuck in Terminating:"
    echo "$terminating_ns" | while read ns; do
        echo "  - $ns"
    done
    echo ""
    
    if [ "$dry_run" = false ]; then
        read -p "Clear finalizers on these namespaces? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo "$terminating_ns" | while read ns; do
                # First, try to delete remaining resources
                echo "Cleaning up resources in namespace: $ns"
                kubectl --kubeconfig=$kubeconfig delete all --all -n "$ns" --force --grace-period=0 2>/dev/null || true
                kubectl --kubeconfig=$kubeconfig delete configmaps,secrets,serviceaccounts,pvc --all -n "$ns" 2>/dev/null || true
                
                # Then clear finalizers
                execute "kubectl --kubeconfig=$kubeconfig get ns \"$ns\" -o json | jq '.spec.finalizers = []' | kubectl --kubeconfig=$kubeconfig replace --raw \"/api/v1/namespaces/$ns/finalize\" -f -" "Clearing finalizers for: $ns"
            done
        else
            echo "Skipping namespace finalizer clearing"
        fi
    else
        echo "$terminating_ns" | while read ns; do
            execute "kubectl --kubeconfig=$kubeconfig get ns \"$ns\" -o json | jq '.spec.finalizers = []' | kubectl --kubeconfig=$kubeconfig replace --raw \"/api/v1/namespaces/$ns/finalize\" -f -" "Would clear finalizers for: $ns"
        done
    fi
else
    echo "✓ No namespaces stuck in Terminating"
fi

echo ""

# Step 3: Check and fix problematic webhooks
echo "=========================================="
echo "Step 3: Checking Webhooks"
echo "=========================================="
echo ""

# Check for webhooks pointing to non-existent services
problematic_wh=$(kubectl --kubeconfig=$kubeconfig get mutatingwebhookconfigurations,validatingwebhookconfigurations -o json 2>/dev/null | \
    jq -r '.items[] | select(.webhooks[]?.clientConfig.service) | 
        .metadata.name as $name |
        .kind as $kind |
        .webhooks[]?.clientConfig.service | 
        "\($kind)|\($name)|\(.name)|\(.namespace)"' 2>/dev/null)

if [ -n "$problematic_wh" ]; then
    echo "Checking webhook service availability..."
    found_issues=false
    
    echo "$problematic_wh" | while IFS='|' read -r kind wh_name svc_name svc_ns; do
        if [ -n "$svc_name" ] && [ -n "$svc_ns" ]; then
            svc_exists=$(kubectl --kubeconfig=$kubeconfig get svc "$svc_name" -n "$svc_ns" 2>/dev/null | wc -l)
            if [ "$svc_exists" -eq 0 ]; then
                echo "  ⚠ $kind '$wh_name' points to non-existent service: $svc_name in $svc_ns"
                found_issues=true
                
                if [ "$dry_run" = false ]; then
                    read -p "    Delete this webhook? (y/N): " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        if [ "$kind" = "MutatingWebhookConfiguration" ]; then
                            execute "kubectl --kubeconfig=$kubeconfig delete mutatingwebhookconfiguration \"$wh_name\"" "Deleting mutating webhook: $wh_name"
                        else
                            execute "kubectl --kubeconfig=$kubeconfig delete validatingwebhookconfiguration \"$wh_name\"" "Deleting validating webhook: $wh_name"
                        fi
                    fi
                else
                    if [ "$kind" = "MutatingWebhookConfiguration" ]; then
                        execute "kubectl --kubeconfig=$kubeconfig delete mutatingwebhookconfiguration \"$wh_name\"" "Would delete mutating webhook: $wh_name"
                    else
                        execute "kubectl --kubeconfig=$kubeconfig delete validatingwebhookconfiguration \"$wh_name\"" "Would delete validating webhook: $wh_name"
                    fi
                fi
            fi
        fi
    done
    
    if [ "$found_issues" = false ]; then
        echo "✓ All webhook services exist"
    fi
else
    echo "✓ No webhooks found"
fi

echo ""

# Step 4: Verify fixes
echo "=========================================="
echo "Step 4: Verification"
echo "=========================================="
echo ""

if [ "$dry_run" = false ]; then
    echo "Waiting 5 seconds for changes to take effect..."
    sleep 5
    
    echo ""
    echo "Checking APIServices:"
    unavailable_after=$(kubectl --kubeconfig=$kubeconfig get apiservices -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.conditions[]? | select(.type=="Available" and .status=="False")) | .metadata.name' 2>/dev/null | wc -l)
    
    if [ "$unavailable_after" -eq 0 ]; then
        echo "  ✓ All APIServices are now available"
    else
        echo "  ⚠ Still have $unavailable_after unavailable APIService(s)"
    fi
    
    echo ""
    echo "Checking stuck namespaces:"
    stuck_after=$(kubectl --kubeconfig=$kubeconfig get ns -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.phase=="Terminating") | .metadata.name' 2>/dev/null | wc -l)
    
    if [ "$stuck_after" -eq 0 ]; then
        echo "  ✓ No namespaces stuck in Terminating"
    else
        echo "  ⚠ Still have $stuck_after namespace(s) stuck"
        echo "  Run detailed diagnosis: ./diagnose-terminating-namespaces.sh $kubeconfig"
    fi
else
    echo "[DRY RUN] Skipping verification"
fi

echo ""
echo "=========================================="
echo "Fix Complete"
echo "=========================================="
echo ""

if [ "$dry_run" = false ]; then
    echo "Next steps:"
    echo "1. Test creating and deleting a namespace"
    echo "2. Monitor for any recurring issues"
    echo "3. Review logs if issues persist:"
    echo "   ./collect-cluster-logs.sh $kubeconfig"
    echo "4. Run health check:"
    echo "   ./cluster-health-check.sh $kubeconfig"
fi
