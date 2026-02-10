#!/bin/bash

# Kasten.io APIService Diagnostic Script
# Diagnoses why Kasten APIServices are timing out during namespace deletion

if [ $# -lt 1 ]; then
    echo "Usage: $0 kubeconfig"
    echo ""
    echo "Example: $0 /path/to/kubeconfig"
    exit 1
fi

kubeconfig=$1
export KUBECONFIG="$kubeconfig"

echo "=========================================="
echo "Kasten.io APIService Diagnosis"
echo "=========================================="
echo ""

# Check APIService status
echo "1. Checking Kasten APIServices status..."
echo "----------------------------------------"
kubectl get apiservices | grep kasten
echo ""

# Check aggregatedapis-svc service
echo "2. Checking aggregatedapis-svc service..."
echo "----------------------------------------"
kubectl get svc aggregatedapis-svc -n kasten-io
echo ""

# Check endpoints
echo "3. Checking aggregatedapis-svc endpoints..."
echo "----------------------------------------"
kubectl get endpoints aggregatedapis-svc -n kasten-io
echo ""

# Check if endpoint port matches service port
SVC_PORT=$(kubectl get svc aggregatedapis-svc -n kasten-io -o jsonpath='{.spec.ports[0].port}')
ENDPOINT_PORT=$(kubectl get endpoints aggregatedapis-svc -n kasten-io -o jsonpath='{.subsets[0].ports[0].port}')

echo "Service Port: $SVC_PORT"
echo "Endpoint Port: $ENDPOINT_PORT"
if [ "$SVC_PORT" != "$ENDPOINT_PORT" ]; then
    echo "⚠️  WARNING: Port mismatch! Service expects $SVC_PORT but endpoint has $ENDPOINT_PORT"
    echo "   This could cause API timeouts!"
fi
echo ""

# Check aggregatedapis-svc pod
echo "4. Checking aggregatedapis-svc pod status..."
echo "----------------------------------------"
kubectl get pods -n kasten-io | grep aggregatedapis-svc
echo ""

# Get pod name
POD_NAME=$(kubectl get pods -n kasten-io -l app=k10,apiserver=true -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$POD_NAME" ]; then
    echo "5. Checking aggregatedapis-svc pod details..."
    echo "----------------------------------------"
    kubectl describe pod -n kasten-io "$POD_NAME" | head -50
    echo ""
    
    echo "6. Checking aggregatedapis-svc pod logs (last 50 lines)..."
    echo "----------------------------------------"
    kubectl logs -n kasten-io "$POD_NAME" --tail=50
    echo ""
    
    echo "7. Checking what port the pod is actually listening on..."
    echo "----------------------------------------"
    kubectl exec -n kasten-io "$POD_NAME" -- netstat -tlnp 2>/dev/null | grep LISTEN || \
    kubectl exec -n kasten-io "$POD_NAME" -- ss -tlnp 2>/dev/null | grep LISTEN || \
    echo "  (Cannot check - netstat/ss not available in container)"
    echo ""
fi

# Check other stuck pods
echo "8. Checking stuck Kasten pods..."
echo "----------------------------------------"
kubectl get pods -n kasten-io | grep -E "Init:|ContainerCreating|Error|CrashLoop"
echo ""

# Test API endpoint
echo "9. Testing API endpoint connectivity..."
echo "----------------------------------------"
echo "Attempting to test aggregatedapis-svc endpoint..."
echo ""

# Try to test from within cluster
kubectl run -it --rm kasten-test-$(date +%s) \
    --image=curlimages/curl \
    --restart=Never \
    --rm \
    -- curl -k -v --max-time 10 \
    https://aggregatedapis-svc.kasten-io.svc:443/apis/actions.kio.kasten.io/v1alpha1 2>&1 | head -30 || \
    echo "  ⚠️  API endpoint test failed or timed out"
echo ""

echo "=========================================="
echo "Diagnosis Complete"
echo "=========================================="
echo ""
echo "Key Findings:"
echo "- Check if endpoint port matches service port"
echo "- Check aggregatedapis-svc pod logs for errors"
echo "- Check if other stuck pods are affecting the service"
echo ""
echo "If the endpoint port is wrong or the pod is unresponsive,"
echo "consider restarting the pod or deleting the APIServices."
