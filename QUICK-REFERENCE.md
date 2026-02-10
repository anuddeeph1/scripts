# Namespace Stuck in Terminating - Quick Reference

## 🎯 The Problem

When you delete a namespace, it gets stuck in `Terminating` state and never completes deletion.

## 🔍 Root Causes (Most to Least Common)

1. **Unavailable APIServices** - Blocks resource enumeration
2. **Finalizers on namespace** - Blocks deletion completion  
3. **Resources still present** - Blocks namespace cleanup
4. **Webhooks blocking** - Blocks deletion requests
5. **Controller/Operator down** - Can't process cleanup

## 🚀 Quick Fix (3 Steps)

### Step 1: Delete Broken APIServices
```bash
kubectl get apiservices | grep -v "True"
kubectl delete apiservice <broken-apiservice>
```

### Step 2: Delete All Resources
```bash
kubectl delete all --all -n <namespace> --force --grace-period=0
kubectl delete configmaps,secrets,serviceaccounts,pvc --all -n <namespace>
```

### Step 3: Clear Finalizers
```bash
kubectl get ns <namespace> -o json | \
  jq '.spec.finalizers = []' | \
  kubectl replace --raw "/api/v1/namespaces/<namespace>/finalize" -f -
```

## 🛠️ Diagnostic Tools

### Full Diagnosis
```bash
./diagnose-terminating-namespaces.sh <kubeconfig> [namespace]
```

### Quick Check
```bash
./quick-check-terminating.sh <kubeconfig>
```

### Automated Fix
```bash
./force-delete-namespace.sh <kubeconfig> <namespace>
```

## 📋 Manual Diagnostic Steps

1. **Check finalizers:**
   ```bash
   kubectl get ns <ns> -o jsonpath='{.spec.finalizers[*]}'
   ```

2. **Check resources:**
   ```bash
   kubectl get all -n <ns>
   kubectl get configmaps,secrets,serviceaccounts,pvc -n <ns>
   ```

3. **Check APIServices:**
   ```bash
   kubectl get apiservices | grep -v "True"
   ```

4. **Check webhooks:**
   ```bash
   kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations
   ```

## ⚡ Common Scenarios

### Scenario: New namespace stuck immediately
**Cause:** APIService unavailable  
**Fix:** Delete APIService → Clear finalizers

### Scenario: Namespace stuck after resource deletion
**Cause:** Finalizers on namespace  
**Fix:** Clear finalizers

### Scenario: Namespace stuck for days
**Cause:** APIService unavailable (most common)  
**Fix:** Delete APIService → Clear finalizers

## 🎓 Understanding Finalizers

- **`kubernetes` finalizer** = Normal, added by Kubernetes
- **Other finalizers** = Added by controllers/operators
- **Problem:** If controller is down, finalizer never clears
- **Solution:** Manually clear finalizers

## 🛡️ Prevention

1. Monitor APIServices: `kubectl get apiservices | grep -v "True"`
2. Delete resources before namespace: `kubectl delete all --all -n <ns>`
3. Check controllers are running: `kubectl get pods -A | grep <controller>`
4. Use timeout: `kubectl delete ns <ns> --timeout=60s`

## 📚 Full Documentation

- **Complete Guide:** `NAMESPACE-TERMINATING-GUIDE.md`
- **Flowchart:** `NAMESPACE-TERMINATING-FLOWCHART.md`
- **Diagnostic Script:** `diagnose-terminating-namespaces.sh`
- **Force Delete Script:** `force-delete-namespace.sh`
