# Kyverno Cleanup - Critical Commands

## 🔴 CRITICAL: Delete APIServices First (This is what's blocking everything!)

```bash
# Delete the broken APIServices that are blocking namespace deletion
kubectl delete apiservice v1.reports.kyverno.io
kubectl delete apiservice v1alpha1.openreports.io
kubectl delete apiservice v1alpha2.wgpolicyk8s.io
```

## Step 2: Clear Finalizers on Stuck Namespaces

After deleting APIServices, clear finalizers on all stuck namespaces:

```bash
# Function to clear finalizers (run this first)
clear_ns() {
  kubectl get ns "$1" -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/$1/finalize" -f -
}

# Clear each stuck namespace
clear_ns kyverno
clear_ns delete-ns
clear_ns migration-test17
clear_ns prabhu-test
clear_ns test
clear_ns test1
clear_ns test2
clear_ns test3
clear_ns test4
```

## Alternative: One-liner for each namespace

```bash
# kyverno
kubectl get ns kyverno -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/kyverno/finalize" -f -

# delete-ns
kubectl get ns delete-ns -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/delete-ns/finalize" -f -

# migration-test17
kubectl get ns migration-test17 -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/migration-test17/finalize" -f -

# prabhu-test
kubectl get ns prabhu-test -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/prabhu-test/finalize" -f -

# test
kubectl get ns test -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/test/finalize" -f -

# test1
kubectl get ns test1 -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/test1/finalize" -f -

# test2
kubectl get ns test2 -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/test2/finalize" -f -

# test3
kubectl get ns test3 -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/test3/finalize" -f -

# test4
kubectl get ns test4 -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/test4/finalize" -f -
```

## Verify Cleanup

```bash
# Check APIServices
kubectl get apiservices | grep -E "kyverno|wgpolicyk8s|openreports"

# Check stuck namespaces
kubectl get ns | grep Terminating
```

## What You've Already Done ✓

- ✅ Deleted ClusterRoles
- ✅ Deleted ClusterRoleBindings  
- ✅ Deleted WebhookConfigurations (already gone)
- ✅ Force deleted kyverno namespace (but stuck due to APIServices)

## What's Missing ❌

- ❌ **APIServices NOT deleted** - This is the blocker!
- ❌ Finalizers not cleared on stuck namespaces

## Root Cause

The **APIServices** are cluster-scoped resources that reference the `kyverno-reports-server` service. Even though the namespace is being deleted, Kubernetes cannot complete the deletion because it's trying to enumerate resources from these broken APIs. **Delete the APIServices first**, then clear finalizers.
