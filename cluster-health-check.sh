#!/bin/bash

# Cluster Health Check Script
# Diagnoses cluster-wide issues causing namespaces to get stuck in Terminating

if [ $# -lt 1 ]; then
    echo "Usage: $0 kubeconfig"
    echo ""
    echo "* kubeconfig: Absolute path of kubeconfig file for the cluster"
    echo ""
    echo "Eg: $0 /home/user/.kube/config"
    exit 1
fi

kubeconfig=$1

echo "=========================================="
echo "Cluster Health Diagnostic Tool"
echo "=========================================="
echo ""

# Function to check component status
check_component() {
    local component=$1
    local namespace=$2
    echo "Checking $component in namespace $namespace..."
    
    pods=$(kubectl --kubeconfig=$kubeconfig get pods -n "$namespace" --no-headers 2>/dev/null | wc -l)
    ready=$(kubectl --kubeconfig=$kubeconfig get pods -n "$namespace" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    
    if [ "$pods" -eq 0 ]; then
        echo "  ❌ No pods found"
        return 1
    elif [ "$ready" -lt "$pods" ]; then
        echo "  ⚠ Found $pods pod(s), but only $ready are Running"
        kubectl --kubeconfig=$kubeconfig get pods -n "$namespace" --no-headers 2>/dev/null | \
            awk '{if ($3 != "Running") print "    - " $1 " (" $3 ")"}'
        return 1
    else
        echo "  ✓ All $pods pod(s) are Running"
        return 0
    fi
}

echo "=========================================="
echo "1. Checking Core Components"
echo "=========================================="
echo ""

# Check kube-system components
check_component "kube-apiserver" "kube-system"
check_component "kube-controller-manager" "kube-system"
check_component "kube-scheduler" "kube-system"
check_component "etcd" "kube-system"

echo ""
echo "=========================================="
echo "2. Checking APIServices (CRITICAL)"
echo "=========================================="
echo ""

unavailable_apis=$(kubectl --kubeconfig=$kubeconfig get apiservices -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.conditions[]? | select(.type=="Available" and .status=="False")) | .metadata.name' 2>/dev/null)

if [ -n "$unavailable_apis" ]; then
    echo "🔴 Found unavailable APIServices (these block ALL namespace deletions):"
    echo ""
    echo "$unavailable_apis" | while read api; do
        reason=$(kubectl --kubeconfig=$kubeconfig get apiservice "$api" -o jsonpath='{.status.conditions[?(@.type=="Available")].reason}' 2>/dev/null)
        message=$(kubectl --kubeconfig=$kubeconfig get apiservice "$api" -o jsonpath='{.status.conditions[?(@.type=="Available")].message}' 2>/dev/null)
        service=$(kubectl --kubeconfig=$kubeconfig get apiservice "$api" -o jsonpath='{.spec.service.name}' 2>/dev/null)
        namespace=$(kubectl --kubeconfig=$kubeconfig get apiservice "$api" -o jsonpath='{.spec.service.namespace}' 2>/dev/null)
        
        echo "  APIService: $api"
        echo "    Reason: $reason"
        echo "    Message: $message"
        echo "    Service: $service in namespace $namespace"
        
        # Check if service exists
        if [ -n "$service" ] && [ -n "$namespace" ]; then
            svc_exists=$(kubectl --kubeconfig=$kubeconfig get svc "$service" -n "$namespace" 2>/dev/null | wc -l)
            if [ "$svc_exists" -eq 0 ]; then
                echo "    ❌ Service does not exist!"
            else
                endpoints=$(kubectl --kubeconfig=$kubeconfig get endpoints "$service" -n "$namespace" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
                if [ -z "$endpoints" ]; then
                    echo "    ❌ Service has no endpoints!"
                    echo "    Checking pods for service..."
                    selector=$(kubectl --kubeconfig=$kubeconfig get svc "$service" -n "$namespace" -o jsonpath='{.spec.selector}' 2>/dev/null)
                    if [ -n "$selector" ]; then
                        pods=$(kubectl --kubeconfig=$kubeconfig get pods -n "$namespace" -l "$selector" --no-headers 2>/dev/null | wc -l)
                        echo "    Found $pods pod(s) matching selector"
                    fi
                else
                    echo "    ✓ Service has endpoints"
                fi
            fi
        fi
        echo ""
    done
else
    echo "✓ All APIServices are available"
fi

echo ""
echo "=========================================="
echo "3. Checking Webhooks"
echo "=========================================="
echo ""

# Check mutating webhooks
mutating_wh=$(kubectl --kubeconfig=$kubeconfig get mutatingwebhookconfigurations -o json 2>/dev/null | \
    jq -r '.items[] | select(.webhooks[]?.clientConfig.service) | .metadata.name' 2>/dev/null | wc -l)

validating_wh=$(kubectl --kubeconfig=$kubeconfig get validatingwebhookconfigurations -o json 2>/dev/null | \
    jq -r '.items[] | select(.webhooks[]?.clientConfig.service) | .metadata.name' 2>/dev/null | wc -l)

echo "Found $mutating_wh mutating webhook(s) and $validating_wh validating webhook(s)"

# Check for webhooks pointing to unavailable services
problematic_wh=$(kubectl --kubeconfig=$kubeconfig get mutatingwebhookconfigurations,validatingwebhookconfigurations -o json 2>/dev/null | \
    jq -r '.items[] | select(.webhooks[]?.clientConfig.service) | 
        .metadata.name as $name |
        .webhooks[]?.clientConfig.service | 
        "\($name)|\(.name)|\(.namespace)"' 2>/dev/null)

if [ -n "$problematic_wh" ]; then
    echo ""
    echo "Checking webhook service availability..."
    echo "$problematic_wh" | while IFS='|' read -r wh_name svc_name svc_ns; do
        if [ -n "$svc_name" ] && [ -n "$svc_ns" ]; then
            svc_exists=$(kubectl --kubeconfig=$kubeconfig get svc "$svc_name" -n "$svc_ns" 2>/dev/null | wc -l)
            if [ "$svc_exists" -eq 0 ]; then
                echo "  ⚠ Webhook '$wh_name' points to non-existent service: $svc_name in $svc_ns"
            fi
        fi
    done
fi

echo ""
echo "=========================================="
echo "4. Checking Controller Manager"
echo "=========================================="
echo ""

# Check controller manager logs for errors
cm_pod=$(kubectl --kubeconfig=$kubeconfig get pods -n kube-system -l component=kube-controller-manager --no-headers 2>/dev/null | head -1 | awk '{print $1}')

if [ -n "$cm_pod" ]; then
    echo "Controller Manager pod: $cm_pod"
    echo "Recent errors (last 20 lines):"
    kubectl --kubeconfig=$kubeconfig logs -n kube-system "$cm_pod" --tail=20 2>/dev/null | grep -i "error\|failed\|timeout" | tail -5 || echo "  No recent errors found"
else
    echo "❌ Controller Manager pod not found"
fi

echo ""
echo "=========================================="
echo "5. Checking API Server"
echo "=========================================="
echo ""

# Check API server pods
api_pods=$(kubectl --kubeconfig=$kubeconfig get pods -n kube-system -l component=kube-apiserver --no-headers 2>/dev/null | awk '{print $1}')

if [ -n "$api_pods" ]; then
    echo "API Server pods:"
    echo "$api_pods" | while read pod; do
        status=$(kubectl --kubeconfig=$kubeconfig get pod "$pod" -n kube-system -o jsonpath='{.status.phase}' 2>/dev/null)
        echo "  - $pod: $status"
    done
    echo ""
    echo "Recent API server errors (from first pod, last 20 lines):"
    first_pod=$(echo "$api_pods" | head -1)
    kubectl --kubeconfig=$kubeconfig logs -n kube-system "$first_pod" --tail=20 2>/dev/null | grep -i "error\|failed\|timeout\|503\|500" | tail -5 || echo "  No recent errors found"
else
    echo "❌ API Server pods not found"
fi

echo ""
echo "=========================================="
echo "6. Checking etcd"
echo "=========================================="
echo ""

# Check etcd pods
etcd_pods=$(kubectl --kubeconfig=$kubeconfig get pods -n kube-system -l component=etcd --no-headers 2>/dev/null | awk '{print $1}')

if [ -n "$etcd_pods" ]; then
    echo "etcd pods:"
    echo "$etcd_pods" | while read pod; do
        status=$(kubectl --kubeconfig=$kubeconfig get pod "$pod" -n kube-system -o jsonpath='{.status.phase}' 2>/dev/null)
        echo "  - $pod: $status"
    done
    echo ""
    echo "Recent etcd errors (from first pod, last 20 lines):"
    first_pod=$(echo "$etcd_pods" | head -1)
    kubectl --kubeconfig=$kubeconfig logs -n kube-system "$first_pod" --tail=20 2>/dev/null | grep -i "error\|failed\|timeout\|slow" | tail -5 || echo "  No recent errors found"
else
    echo "ℹ etcd pods not found in kube-system (may be running as static pods)"
fi

echo ""
echo "=========================================="
echo "7. Checking Network/CNI"
echo "=========================================="
echo ""

# Check CNI pods
cni_pods=$(kubectl --kubeconfig=$kubeconfig get pods -A --no-headers 2>/dev/null | grep -E "calico|flannel|weave|cilium" | wc -l)

if [ "$cni_pods" -gt 0 ]; then
    echo "Found $cni_pods CNI-related pod(s)"
    kubectl --kubeconfig=$kubeconfig get pods -A --no-headers 2>/dev/null | grep -E "calico|flannel|weave|cilium" | head -5 | \
        awk '{print "  - " $2 " in " $1 " (" $4 ")"}'
else
    echo "ℹ No CNI pods found (may be using host network)"
fi

echo ""
echo "=========================================="
echo "8. Checking Stuck Namespaces"
echo "=========================================="
echo ""

terminating_ns=$(kubectl --kubeconfig=$kubeconfig get ns -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.phase=="Terminating") | .metadata.name' 2>/dev/null)

if [ -n "$terminating_ns" ]; then
    count=$(echo "$terminating_ns" | wc -l | tr -d ' ')
    echo "Found $count namespace(s) stuck in Terminating:"
    echo "$terminating_ns" | while read ns; do
        age=$(kubectl --kubeconfig=$kubeconfig get ns "$ns" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
        deletion=$(kubectl --kubeconfig=$kubeconfig get ns "$ns" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)
        echo "  - $ns (deletion requested: $deletion)"
    done
else
    echo "✓ No namespaces stuck in Terminating"
fi

echo ""
echo "=========================================="
echo "9. Summary & Recommendations"
echo "=========================================="
echo ""

if [ -n "$unavailable_apis" ]; then
    echo "🔴 CRITICAL: Unavailable APIServices detected"
    echo "   This is likely causing ALL namespace deletions to fail"
    echo ""
    echo "   Fix: Delete the broken APIServices:"
    echo "$unavailable_apis" | while read api; do
        echo "     kubectl --kubeconfig=$kubeconfig delete apiservice $api"
    done
    echo ""
fi

if [ -n "$terminating_ns" ]; then
    echo "🔴 Namespaces stuck in Terminating state"
    echo "   Run detailed diagnosis:"
    echo "     ./diagnose-terminating-namespaces.sh $kubeconfig"
    echo ""
fi

echo "Next Steps:"
echo "1. Review logs (see CLUSTER-LOGS-GUIDE.md)"
echo "2. Fix unavailable APIServices (if any)"
echo "3. Check controller manager logs for errors"
echo "4. Verify etcd health"
echo "5. Check API server performance"

echo ""
echo "=========================================="
echo "Diagnostic Complete"
echo "=========================================="
