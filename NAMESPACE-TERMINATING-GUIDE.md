# Understanding Namespace Stuck in Terminating State

## Overview

When you delete a namespace, Kubernetes goes through a **graceful deletion process**. If this process gets blocked, the namespace remains in `Terminating` state indefinitely.

## Why Namespaces Get Stuck in Terminating

### The Deletion Process

When you run `kubectl delete ns <namespace>`, Kubernetes:

1. **Sets deletion timestamp** - Marks namespace for deletion
2. **Enumerates all resources** - Lists all resources in the namespace
3. **Calls finalizers** - Executes cleanup logic for each resource
4. **Waits for resources to delete** - Resources must be removed before namespace can be deleted
5. **Removes finalizers** - Clears namespace finalizers
6. **Deletes namespace** - Removes namespace object

**If ANY step fails or gets blocked, the namespace stays in Terminating state.**

---

## Common Root Causes

### 1. 🔴 **Finalizers Blocking Deletion** (Most Common)

**What are Finalizers?**
- Finalizers are markers that prevent deletion until cleanup is complete
- They're used by controllers/operators to perform cleanup tasks
- Common finalizers: `kubernetes`, `controller-xyz`, `operator-xyz`

**Why it blocks:**
- If a finalizer controller is down/crashed, it can't remove its finalizer
- Namespace waits indefinitely for the finalizer to be cleared

**Example:**
```yaml
spec:
  finalizers:
    - kubernetes
    - controller-manager
```

### 2. 🔴 **Unavailable APIServices** (Very Common)

**What happens:**
- Kubernetes tries to enumerate ALL resource types during namespace deletion
- If an APIService is unavailable (e.g., `MissingEndpoints`), the enumeration fails
- Namespace deletion gets stuck waiting for the API to respond

**Common culprits:**
- Kyverno reports API (`v1alpha2.wgpolicyk8s.io`)
- Custom operators with broken APIServices
- Aggregated APIs with no backing pods

**Example:**
```
APIService: v1alpha2.wgpolicyk8s.io
Status: False (MissingEndpoints)
Reason: endpoints for service/kyverno-reports-server have no addresses
```

### 3. 🟠 **Resources Still Present**

**What happens:**
- Some resources have finalizers that prevent deletion
- Pods stuck in Terminating (can't be killed)
- PVCs that can't be deleted (storage issues)
- Custom Resources with finalizers

**Common resources:**
- Pods with finalizers
- PVCs (PersistentVolumeClaims)
- Custom Resources (CRDs)
- ConfigMaps/Secrets with finalizers

### 4. 🟠 **Webhooks Blocking**

**What happens:**
- Mutating/Validating webhooks intercept deletion requests
- If webhook is down/unreachable, deletion hangs
- Webhooks with namespace selectors can block

**Example:**
- Kyverno webhooks
- Policy enforcement webhooks
- Custom admission controllers

### 5. 🟡 **Controller/Operator Issues**

**What happens:**
- Controllers managing resources in the namespace are down
- Operators can't process deletion requests
- Resources wait for controller to clean them up

---

## Step-by-Step Diagnostic Process

### Step 1: Identify Stuck Namespaces

```bash
# List all Terminating namespaces
kubectl get ns | grep Terminating

# Or use the diagnostic script
./diagnose-terminating-namespaces.sh /path/to/kubeconfig
```

### Step 2: Check Finalizers

```bash
# Check finalizers on the namespace
kubectl get ns <namespace> -o jsonpath='{.spec.finalizers[*]}'

# Full namespace details
kubectl get ns <namespace> -o yaml
```

**What to look for:**
- Any finalizers listed (especially non-standard ones)
- `kubernetes` finalizer is normal, but shouldn't block indefinitely

### Step 3: Check Remaining Resources

```bash
# List all resources in the namespace
kubectl get all -n <namespace>

# Check for specific resource types
kubectl get pods -n <namespace>
kubectl get pvc -n <namespace>
kubectl get configmaps -n <namespace>
kubectl get serviceaccounts -n <namespace>

# Check for Custom Resources
kubectl api-resources --verbs=list --namespaced -o name | \
  xargs -I {} kubectl get {} -n <namespace>
```

**What to look for:**
- Resources that won't delete
- Resources with finalizers
- Pods stuck in Terminating

### Step 4: Check APIServices

```bash
# List all APIServices
kubectl get apiservices

# Check for unavailable ones
kubectl get apiservices | grep -v "True"

# Detailed check
kubectl get apiservice <name> -o yaml
```

**What to look for:**
- APIServices with `Available=False`
- `MissingEndpoints` reason
- APIServices pointing to services in the namespace being deleted

### Step 5: Check Webhooks

```bash
# Check mutating webhooks
kubectl get mutatingwebhookconfigurations

# Check validating webhooks
kubectl get validatingwebhookconfigurations

# Check webhook details
kubectl get mutatingwebhookconfiguration <name> -o yaml
```

**What to look for:**
- Webhooks with namespace selectors matching your namespace
- Webhooks pointing to services that are down

### Step 6: Check Controller/Operator Status

```bash
# Check if controllers are running
kubectl get pods -n <controller-namespace>

# Check controller logs
kubectl logs -n <controller-namespace> <controller-pod>
```

**What to look for:**
- Controllers that are down/crashed
- Controllers that manage resources in the stuck namespace

---

## Fix Procedures

### Fix 1: Clear Finalizers (Most Common Fix)

**When to use:** Namespace has finalizers blocking deletion

```bash
# Method 1: Direct API call (recommended)
kubectl get ns <namespace> -o json | \
  jq '.spec.finalizers = []' | \
  kubectl replace --raw "/api/v1/namespaces/<namespace>/finalize" -f -

# Method 2: Using kubectl proxy (if Method 1 fails)
kubectl get namespace <namespace> -o json | \
  jq '.spec = {"finalizers":[]}' > /tmp/ns.json

kubectl proxy &
PROXY_PID=$!
sleep 2

curl -H "Content-Type: application/json" -X PUT \
  --data-binary @/tmp/ns.json \
  http://localhost:8001/api/v1/namespaces/<namespace>/finalize

kill $PROXY_PID
rm /tmp/ns.json
```

### Fix 2: Delete Broken APIServices

**When to use:** APIServices are unavailable and blocking enumeration

```bash
# List unavailable APIServices
kubectl get apiservices | grep -v "True"

# Delete the broken APIServices
kubectl delete apiservice <apiservice-name>

# Common Kyverno APIServices
kubectl delete apiservice v1.reports.kyverno.io
kubectl delete apiservice v1alpha1.openreports.io
kubectl delete apiservice v1alpha2.wgpolicyk8s.io
```

**⚠️ Warning:** Only delete APIServices if you're sure they're not needed or can be recreated.

### Fix 3: Force Delete Resources

**When to use:** Resources won't delete normally

```bash
# Force delete pods
kubectl delete pods --all -n <namespace> --force --grace-period=0

# Delete PVCs
kubectl delete pvc --all -n <namespace>

# Delete ConfigMaps/Secrets/ServiceAccounts
kubectl delete configmaps,secrets,serviceaccounts --all -n <namespace>

# Delete all resources
kubectl delete all --all -n <namespace> --force --grace-period=0
```

### Fix 4: Clear Resource Finalizers

**When to use:** Resources have finalizers preventing deletion

```bash
# For a specific resource
kubectl patch <resource-type> <resource-name> -n <namespace> \
  -p '{"metadata":{"finalizers":[]}}' --type=merge

# Example: Clear pod finalizers
kubectl patch pod <pod-name> -n <namespace> \
  -p '{"metadata":{"finalizers":[]}}' --type=merge
```

### Fix 5: Delete/Disable Problematic Webhooks

**When to use:** Webhooks are blocking deletion

```bash
# Delete mutating webhook
kubectl delete mutatingwebhookconfiguration <name>

# Delete validating webhook
kubectl delete validatingwebhookconfiguration <name>
```

**⚠️ Warning:** Be careful - this might affect other namespaces.

---

## Complete Fix Workflow

### Automated Fix Script

Use the provided script:
```bash
./force-delete-namespace.sh /path/to/kubeconfig <namespace>
```

### Manual Fix Steps

1. **Diagnose the issue:**
   ```bash
   ./diagnose-terminating-namespaces.sh /path/to/kubeconfig <namespace>
   ```

2. **Delete remaining resources:**
   ```bash
   kubectl delete all --all -n <namespace> --force --grace-period=0
   kubectl delete configmaps,secrets,serviceaccounts,pvc --all -n <namespace>
   ```

3. **Delete broken APIServices (if any):**
   ```bash
   kubectl get apiservices | grep -v "True"
   kubectl delete apiservice <broken-apiservice>
   ```

4. **Clear namespace finalizers:**
   ```bash
   kubectl get ns <namespace> -o json | \
     jq '.spec.finalizers = []' | \
     kubectl replace --raw "/api/v1/namespaces/<namespace>/finalize" -f -
   ```

5. **Verify deletion:**
   ```bash
   kubectl get ns <namespace>
   ```

---

## Prevention Strategies

### 1. **Monitor APIServices**

Regularly check for unavailable APIServices:
```bash
kubectl get apiservices | grep -v "True"
```

### 2. **Clean Up Before Deletion**

Before deleting a namespace:
```bash
# Delete all resources first
kubectl delete all --all -n <namespace>
kubectl delete configmaps,secrets,serviceaccounts --all -n <namespace>

# Then delete namespace
kubectl delete ns <namespace>
```

### 3. **Check Controller Health**

Ensure controllers/operators are running:
```bash
kubectl get pods -n <operator-namespace>
```

### 4. **Avoid Finalizers When Possible**

When creating resources, avoid adding finalizers unless necessary.

### 5. **Use Timeout Flags**

When deleting, use timeout to avoid hanging:
```bash
kubectl delete ns <namespace> --timeout=60s
```

---

## Troubleshooting Checklist

Use this checklist when a namespace is stuck:

- [ ] Check namespace finalizers: `kubectl get ns <ns> -o jsonpath='{.spec.finalizers[*]}'`
- [ ] List remaining resources: `kubectl get all -n <ns>`
- [ ] Check APIServices: `kubectl get apiservices | grep -v "True"`
- [ ] Check webhooks: `kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations`
- [ ] Check controller pods: `kubectl get pods -A | grep <controller>`
- [ ] Check resource finalizers: `kubectl get <resource> -n <ns> -o yaml | grep finalizers`
- [ ] Check deletion timestamp: `kubectl get ns <ns> -o jsonpath='{.metadata.deletionTimestamp}'`
- [ ] Check events: `kubectl get events -n <ns> --sort-by='.lastTimestamp'`

---

## Quick Reference Commands

```bash
# Diagnose
./diagnose-terminating-namespaces.sh <kubeconfig> [namespace]

# Quick check
./quick-check-terminating.sh <kubeconfig>

# Force delete
./force-delete-namespace.sh <kubeconfig> <namespace>

# Manual clear finalizers
kubectl get ns <ns> -o json | jq '.spec.finalizers = []' | \
  kubectl replace --raw "/api/v1/namespaces/<ns>/finalize" -f -

# Delete all resources
kubectl delete all --all -n <ns> --force --grace-period=0
kubectl delete configmaps,secrets,serviceaccounts,pvc --all -n <ns>
```

---

## Understanding the `kubernetes` Finalizer

The `kubernetes` finalizer is **normal** and added by Kubernetes itself. It should be automatically removed when:
- All resources in the namespace are deleted
- All APIServices can enumerate resources successfully
- No blocking conditions exist

If the namespace is stuck with only the `kubernetes` finalizer, it usually means:
1. Resources are still present (check with `kubectl get all -n <ns>`)
2. APIServices are unavailable (check with `kubectl get apiservices`)
3. Some resource has a finalizer that's not being cleared

---

## Common Scenarios

### Scenario 1: New Namespace Stuck Immediately

**Cause:** APIService unavailable or webhook blocking
**Fix:** Delete broken APIService or webhook

### Scenario 2: Namespace Stuck After Resource Deletion

**Cause:** Finalizers on resources or namespace
**Fix:** Clear finalizers

### Scenario 3: Namespace Stuck for Days/Weeks

**Cause:** APIService unavailable (most common)
**Fix:** Delete the broken APIService, then clear finalizers

### Scenario 4: Multiple Namespaces Stuck

**Cause:** Cluster-wide issue (APIService, webhook, or controller)
**Fix:** Fix the root cause (APIService/webhook/controller)

---

## Summary

**Most Common Causes (in order):**
1. Unavailable APIServices (blocks enumeration)
2. Finalizers on namespace (blocks deletion)
3. Resources with finalizers (blocks cleanup)
4. Webhooks blocking (blocks deletion requests)

**Most Common Fix:**
1. Delete broken APIServices
2. Force delete remaining resources
3. Clear namespace finalizers

**Prevention:**
- Monitor APIService health
- Clean up resources before deleting namespace
- Ensure controllers/operators are running
