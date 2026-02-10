# Namespace Stuck in Terminating - Diagnostic Flowchart

## Quick Decision Tree

```
┌─────────────────────────────────────┐
│ Namespace Stuck in Terminating?     │
└──────────────┬──────────────────────┘
               │
               ▼
    ┌──────────────────────┐
    │ Run Diagnostic Script │
    │ ./diagnose-terminating│
    │ -namespaces.sh        │
    └──────────┬───────────┘
               │
               ▼
    ┌──────────────────────┐
    │ Check Finalizers     │
    │ kubectl get ns -o    │
    │ jsonpath='{.spec...}'│
    └──────────┬───────────┘
               │
        ┌──────┴──────┐
        │             │
        ▼             ▼
    Has Finalizers?  No Finalizers?
        │             │
        │             ▼
        │    ┌─────────────────┐
        │    │ Check Resources │
        │    │ kubectl get all │
        │    └────────┬────────┘
        │             │
        │      ┌──────┴──────┐
        │      │             │
        │      ▼             ▼
        │  Resources?    No Resources?
        │      │             │
        │      │             ▼
        │      │    ┌────────────────┐
        │      │    │ Check APISvc   │
        │      │    │ kubectl get    │
        │      │    │ apiservices    │
        │      │    └────────┬───────┘
        │      │             │
        │      │      ┌──────┴──────┐
        │      │      │             │
        │      │      ▼             ▼
        │      │  Unavailable?   Available?
        │      │      │             │
        │      │      │             ▼
        │      │      │    ┌────────────────┐
        │      │      │    │ Check Webhooks │
        │      │      │    └────────┬───────┘
        │      │      │             │
        │      └──────┴─────────────┘
        │
        ▼
┌───────────────────────┐
│ DIAGNOSIS COMPLETE    │
│ Apply Fix Below       │
└───────────────────────┘
```

## Step-by-Step Diagnostic Process

### Step 1: Initial Check
```bash
kubectl get ns <namespace>
```
**If Status = Terminating → Continue**
**If Status = Active → Not stuck, normal deletion**

---

### Step 2: Check Finalizers
```bash
kubectl get ns <namespace> -o jsonpath='{.spec.finalizers[*]}'
```

**Decision Point:**
- **Has finalizers?** → Go to Step 3
- **No finalizers?** → Go to Step 4

---

### Step 3: Check Resources
```bash
kubectl get all -n <namespace>
kubectl get configmaps,secrets,serviceaccounts,pvc -n <namespace>
```

**Decision Point:**
- **Resources present?** → Fix: Delete resources first
- **No resources?** → Go to Step 4

**Fix for Resources:**
```bash
kubectl delete all --all -n <namespace> --force --grace-period=0
kubectl delete configmaps,secrets,serviceaccounts,pvc --all -n <namespace>
```

---

### Step 4: Check APIServices
```bash
kubectl get apiservices | grep -v "True"
```

**Decision Point:**
- **Unavailable APIServices?** → Fix: Delete broken APIServices
- **All available?** → Go to Step 5

**Fix for APIServices:**
```bash
kubectl delete apiservice <broken-apiservice-name>
```

---

### Step 5: Check Webhooks
```bash
kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations
```

**Decision Point:**
- **Problematic webhooks?** → Fix: Delete/disable webhooks
- **No issues?** → Go to Step 6

---

### Step 6: Clear Finalizers
```bash
kubectl get ns <namespace> -o json | \
  jq '.spec.finalizers = []' | \
  kubectl replace --raw "/api/v1/namespaces/<namespace>/finalize" -f -
```

---

## Fix Priority Order

### Priority 1: Delete Broken APIServices (Most Common)
**Why first?** APIServices block enumeration, preventing all other cleanup.

```bash
# Check
kubectl get apiservices | grep -v "True"

# Fix
kubectl delete apiservice v1.reports.kyverno.io
kubectl delete apiservice v1alpha1.openreports.io
kubectl delete apiservice v1alpha2.wgpolicyk8s.io
```

### Priority 2: Delete Remaining Resources
**Why second?** Resources must be gone before namespace can delete.

```bash
# Fix
kubectl delete all --all -n <namespace> --force --grace-period=0
kubectl delete configmaps,secrets,serviceaccounts,pvc --all -n <namespace>
```

### Priority 3: Clear Namespace Finalizers
**Why last?** Finalizers are cleared after resources are gone.

```bash
# Fix
kubectl get ns <namespace> -o json | \
  jq '.spec.finalizers = []' | \
  kubectl replace --raw "/api/v1/namespaces/<namespace>/finalize" -f -
```

---

## Common Patterns

### Pattern 1: New Namespace Stuck Immediately
```
Delete NS → Stuck in Terminating
```
**Most Likely Cause:** APIService unavailable
**Fix:** Delete broken APIService → Clear finalizers

### Pattern 2: Namespace Stuck After Some Time
```
Delete NS → Resources delete → Stuck
```
**Most Likely Cause:** Finalizers on namespace
**Fix:** Clear finalizers

### Pattern 3: Namespace Stuck for Days
```
Delete NS → Stuck for days/weeks
```
**Most Likely Cause:** APIService unavailable (blocks enumeration)
**Fix:** Delete broken APIService → Clear finalizers

### Pattern 4: Multiple Namespaces Stuck
```
Multiple NS → All stuck
```
**Most Likely Cause:** Cluster-wide issue (APIService/webhook)
**Fix:** Fix root cause (APIService/webhook)

---

## Quick Fix Commands (In Order)

```bash
# 1. Delete broken APIServices
kubectl delete apiservice <broken-apiservice>

# 2. Delete all resources
kubectl delete all --all -n <namespace> --force --grace-period=0
kubectl delete configmaps,secrets,serviceaccounts,pvc --all -n <namespace>

# 3. Clear finalizers
kubectl get ns <namespace> -o json | \
  jq '.spec.finalizers = []' | \
  kubectl replace --raw "/api/v1/namespaces/<namespace>/finalize" -f -

# 4. Verify
kubectl get ns <namespace>
```

---

## Why Each Step Matters

### Why APIServices First?
- Kubernetes enumerates ALL resource types during deletion
- If an APIService is down, enumeration fails
- This blocks the entire deletion process
- **Fix this first** to unblock enumeration

### Why Resources Second?
- Resources must be deleted before namespace
- Some resources have finalizers that prevent deletion
- Force delete to remove blockers
- **Fix this second** to clear the namespace

### Why Finalizers Last?
- Finalizers are the last step in deletion
- They're cleared automatically when resources are gone
- If stuck, manually clear them
- **Fix this last** to complete deletion

---

## Prevention Checklist

Before deleting a namespace:

- [ ] Check APIServices are available: `kubectl get apiservices | grep -v "True"`
- [ ] Delete all resources first: `kubectl delete all --all -n <ns>`
- [ ] Check controllers are running: `kubectl get pods -A | grep <controller>`
- [ ] Use timeout: `kubectl delete ns <ns> --timeout=60s`

---

## Automated Tools

### Full Diagnostic
```bash
./diagnose-terminating-namespaces.sh <kubeconfig> [namespace]
```
**Shows:** Finalizers, resources, APIServices, webhooks, fix commands

### Quick Check
```bash
./quick-check-terminating.sh <kubeconfig>
```
**Shows:** Summary of all stuck namespaces

### Force Delete
```bash
./force-delete-namespace.sh <kubeconfig> <namespace>
```
**Does:** Deletes resources, clears finalizers automatically
