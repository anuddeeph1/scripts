# Cluster-Wide Namespace Termination Fix Guide

## Problem Statement

**Every newly created namespace gets stuck in Terminating state** - This indicates a **cluster-wide infrastructure issue**, not a namespace-specific problem.

---

## 🎯 Root Cause Analysis

When **all namespaces** get stuck, the issue is typically:

1. **Unavailable APIServices** (90% of cases)
   - Blocks resource enumeration during namespace deletion
   - Affects ALL namespace deletions cluster-wide

2. **Controller Manager Issues**
   - Namespace controller can't process deletions
   - Affects ALL namespace deletions

3. **etcd Performance Issues**
   - Slow responses block API server
   - Affects ALL operations cluster-wide

4. **Webhook Failures**
   - Admission webhooks blocking deletion requests
   - Affects ALL namespace deletions

---

## 📋 Step-by-Step Fix Process

### Step 1: Run Cluster Health Check

```bash
./cluster-health-check.sh /path/to/kubeconfig
```

**What it checks:**
- Core component status (API server, controller manager, etcd)
- Unavailable APIServices
- Webhook issues
- Stuck namespaces
- Component health

**Output:** Identifies the root cause

---

### Step 2: Collect Logs

```bash
./collect-cluster-logs.sh /path/to/kubeconfig
```

**What it collects:**
- API server logs (full + errors)
- Controller manager logs (full + errors)
- etcd logs (full + errors)
- APIService status
- Webhook configurations
- Cluster state

**Output:** `cluster-logs-<timestamp>/` directory with all logs

---

### Step 3: Review Logs (Priority Order)

#### Priority 1: API Server Logs
```bash
# Check for APIService errors
cat cluster-logs-*/apiserver-errors.log | grep -i "apiservice\|503\|service unavailable"

# Check for timeout errors
cat cluster-logs-*/apiserver-errors.log | grep -i "timeout"

# Check for etcd errors
cat cluster-logs-*/apiserver-errors.log | grep -i "etcd"
```

**What to look for:**
- `503 Service Unavailable` - APIService errors
- `timeout` - Performance issues
- `etcd` errors - etcd connection problems

#### Priority 2: Controller Manager Logs
```bash
# Check for namespace controller errors
cat cluster-logs-*/controller-manager-errors.log | grep -i "namespace"

# Check for finalizer errors
cat cluster-logs-*/controller-manager-errors.log | grep -i "finalizer"
```

**What to look for:**
- `error syncing namespace` - Namespace controller issues
- `failed to delete namespace` - Deletion failures
- `finalizer` errors - Finalizer removal failures

#### Priority 3: etcd Logs
```bash
# Check for performance issues
cat cluster-logs-*/etcd-errors.log | grep -i "slow\|timeout"

# Check for connection issues
cat cluster-logs-*/etcd-errors.log | grep -i "connection"
```

**What to look for:**
- `slow request` - Performance degradation
- `timeout` - etcd not responding
- `connection` errors - Network issues

#### Priority 4: Check Unavailable APIServices
```bash
cat cluster-logs-*/unavailable-apiservices.txt
```

**This is usually the culprit!**

---

### Step 4: Apply Fixes

#### Option A: Automated Fix (Recommended)

```bash
# Dry run first (see what would be fixed)
./fix-cluster-namespace-issues.sh /path/to/kubeconfig --dry-run

# Apply fixes
./fix-cluster-namespace-issues.sh /path/to/kubeconfig
```

**What it fixes:**
- Deletes unavailable APIServices
- Clears finalizers on stuck namespaces
- Removes problematic webhooks

#### Option B: Manual Fix

**Fix 1: Delete Broken APIServices**
```bash
# List unavailable APIServices
kubectl get apiservices | grep -v "True"

# Delete them
kubectl delete apiservice <apiservice-name>

# Common ones (Kyverno)
kubectl delete apiservice v1.reports.kyverno.io
kubectl delete apiservice v1alpha1.openreports.io
kubectl delete apiservice v1alpha2.wgpolicyk8s.io
```

**Fix 2: Clear Finalizers on Stuck Namespaces**
```bash
# List stuck namespaces
kubectl get ns | grep Terminating

# Clear finalizers
for ns in $(kubectl get ns | grep Terminating | awk '{print $1}'); do
  kubectl get ns "$ns" -o json | jq '.spec.finalizers = []' | \
    kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f -
done
```

**Fix 3: Fix etcd Issues (if needed)**
```bash
# Check etcd health
kubectl get componentstatuses

# Check etcd disk space (on master node)
df -h /var/lib/etcd

# Check etcd performance
# SSH to master and check logs
journalctl -u etcd | grep -i "slow\|timeout"
```

---

### Step 5: Verify Fix

```bash
# Test creating and deleting a namespace
kubectl create ns test-fix
kubectl delete ns test-fix

# Check if it deletes successfully (should complete in seconds)
kubectl get ns test-fix

# Check for remaining stuck namespaces
kubectl get ns | grep Terminating

# Run health check again
./cluster-health-check.sh /path/to/kubeconfig
```

---

## 🔍 Log Review Guide

### For Static Pods (API Server, etcd, Controller Manager on Master)

**SSH to master node and run:**

```bash
# API Server logs
journalctl -u kube-apiserver -n 5000 --no-pager | grep -i "error\|failed\|503\|apiservice" > apiserver-errors.log

# Controller Manager logs
journalctl -u kube-controller-manager -n 5000 --no-pager | grep -i "error\|failed\|namespace" > controller-manager-errors.log

# etcd logs
journalctl -u etcd -n 5000 --no-pager | grep -i "error\|failed\|slow\|timeout" > etcd-errors.log

# containerd logs
journalctl -u containerd -n 5000 --no-pager | grep -i "error\|failed\|timeout" > containerd-errors.log
```

### Key Log Patterns to Find

**APIService Errors:**
```
"service unavailable"
"503 Service Unavailable"
"MissingEndpoints"
"no endpoints available"
```

**Namespace Controller Errors:**
```
"error syncing namespace"
"failed to delete namespace"
"namespace deletion failed"
```

**etcd Performance:**
```
"slow request"
"took too long"
"read index timeout"
```

---

## 🚨 Most Common Fix

### The #1 Issue: Unavailable APIServices

**Symptoms:**
- All namespaces get stuck
- `kubectl get apiservices | grep -v "True"` shows unavailable services
- API server logs show `503 Service Unavailable`

**Fix:**
```bash
# 1. Identify broken APIServices
kubectl get apiservices | grep -v "True"

# 2. Delete them
kubectl delete apiservice <broken-apiservice>

# 3. Clear finalizers on stuck namespaces
for ns in $(kubectl get ns | grep Terminating | awk '{print $1}'); do
  kubectl get ns "$ns" -o json | jq '.spec.finalizers = []' | \
    kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f -
done
```

---

## 📊 Complete Workflow

```bash
# 1. Diagnose
./cluster-health-check.sh /path/to/kubeconfig

# 2. Collect logs
./collect-cluster-logs.sh /path/to/kubeconfig

# 3. Review logs (see CLUSTER-LOGS-GUIDE.md)
cat cluster-logs-*/unavailable-apiservices.txt
cat cluster-logs-*/apiserver-errors.log

# 4. Fix (dry run first)
./fix-cluster-namespace-issues.sh /path/to/kubeconfig --dry-run

# 5. Apply fix
./fix-cluster-namespace-issues.sh /path/to/kubeconfig

# 6. Verify
kubectl create ns test && kubectl delete ns test
kubectl get ns | grep Terminating
```

---

## 🛠️ Tools Created

1. **`cluster-health-check.sh`** - Diagnoses cluster-wide issues
2. **`collect-cluster-logs.sh`** - Collects all relevant logs
3. **`fix-cluster-namespace-issues.sh`** - Automated fix script
4. **`CLUSTER-LOGS-GUIDE.md`** - Detailed log review guide

---

## 📝 Checklist

- [ ] Run cluster health check
- [ ] Collect logs from all components
- [ ] Review API server logs for APIService errors
- [ ] Review controller manager logs for namespace errors
- [ ] Review etcd logs for performance issues
- [ ] Check for unavailable APIServices
- [ ] Delete broken APIServices
- [ ] Clear finalizers on stuck namespaces
- [ ] Test namespace creation/deletion
- [ ] Verify no namespaces are stuck

---

## 🎓 Understanding the Issue

### Why All Namespaces Get Stuck

When you delete a namespace, Kubernetes:
1. **Enumerates all resource types** - Queries ALL APIServices
2. **If ANY APIService is unavailable** → Enumeration fails
3. **Namespace deletion blocks** → Waits for enumeration to complete
4. **Result:** ALL namespace deletions fail

### Why APIServices Matter

- APIServices are **cluster-scoped** resources
- They affect **ALL namespaces**
- If one is broken, it blocks **ALL namespace operations**
- This is why **every namespace** gets stuck

---

## 🔧 Prevention

1. **Monitor APIServices:**
   ```bash
   kubectl get apiservices | grep -v "True"
   ```

2. **Monitor Controller Manager:**
   ```bash
   kubectl get pods -n kube-system -l component=kube-controller-manager
   ```

3. **Monitor etcd Performance:**
   ```bash
   kubectl get componentstatuses
   ```

4. **Regular Health Checks:**
   ```bash
   ./cluster-health-check.sh /path/to/kubeconfig
   ```

---

## Summary

**For cluster-wide namespace termination issues:**

1. **Diagnose:** `./cluster-health-check.sh`
2. **Collect Logs:** `./collect-cluster-logs.sh`
3. **Review:** Check `unavailable-apiservices.txt` and error logs
4. **Fix:** `./fix-cluster-namespace-issues.sh`
5. **Verify:** Test namespace creation/deletion

**Most common fix:** Delete unavailable APIServices + Clear finalizers
