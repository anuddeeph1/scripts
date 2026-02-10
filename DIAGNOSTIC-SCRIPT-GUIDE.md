# Namespace Termination Diagnostic Script Guide

## Overview

The `diagnose-terminating-namespaces.sh` script identifies why namespaces are stuck in Terminating state.

## Usage

### Check All Terminating Namespaces
```bash
./diagnose-terminating-namespaces.sh /path/to/kubeconfig
```

### Check Specific Namespace
```bash
./diagnose-terminating-namespaces.sh /path/to/kubeconfig kyverno
```

## What the Script Checks

### 1. **Finalizers** (Most Common Blocker)
- Lists all finalizers on the namespace
- Finalizers prevent namespace deletion until they're cleared
- **Fix**: Clear finalizers using the provided command

### 2. **Resources Still Present**
- Checks for pods, PVCs, services, deployments, statefulsets
- Checks for Custom Resources (CRDs)
- Counts total remaining resources
- **Fix**: Delete or wait for resources to be cleaned up

### 3. **Unavailable APIServices** (Common Blocker)
- Identifies APIServices with `Available=False`
- These block namespace deletion because Kubernetes tries to enumerate resources from them
- **Fix**: Delete the broken APIServices

### 4. **Webhooks**
- Checks for mutating/validating webhooks with namespace selectors
- These can block deletion if they're not responding
- **Fix**: Delete or fix the webhook configurations

### 5. **Known Issues**
- Specifically checks for Kyverno APIServices (common issue)
- Provides specific fix commands

## Common Causes & Fixes

### Cause 1: Finalizers Blocking
**Symptoms**: Finalizers listed in output
**Fix**:
```bash
kubectl --kubeconfig=/path/to/kubeconfig get ns <namespace> -o json | \
  jq '.spec.finalizers = []' | \
  kubectl --kubeconfig=/path/to/kubeconfig replace --raw "/api/v1/namespaces/<namespace>/finalize" -f -
```

### Cause 2: Unavailable APIServices
**Symptoms**: APIServices showing `False (MissingEndpoints)`
**Fix**:
```bash
# Delete the broken APIServices
kubectl --kubeconfig=/path/to/kubeconfig delete apiservice <apiservice-name>
```

### Cause 3: Resources Still Present
**Symptoms**: Pods, PVCs, or other resources still in namespace
**Fix**:
```bash
# Force delete pods
kubectl --kubeconfig=/path/to/kubeconfig delete pods --all -n <namespace> --force --grace-period=0

# Delete PVCs
kubectl --kubeconfig=/path/to/kubeconfig delete pvc --all -n <namespace>
```

### Cause 4: Webhooks Not Responding
**Symptoms**: Webhooks listed in output
**Fix**:
```bash
# Delete problematic webhooks
kubectl --kubeconfig=/path/to/kubeconfig delete mutatingwebhookconfiguration <webhook-name>
kubectl --kubeconfig=/path/to/kubeconfig delete validatingwebhookconfiguration <webhook-name>
```

## Example Output

```
==========================================
Namespace Termination Diagnostic Tool
==========================================

Scanning for namespaces stuck in Terminating state...

Found 3 namespace(s) stuck in Terminating state:
  - kyverno
  - migration-test17
  - test

==========================================
Diagnosing namespace: kyverno
==========================================
Status: Terminating
Deletion requested at: 2026-02-04T15:00:00Z

1. Checking Finalizers:
  🔴 Found finalizers blocking deletion:
    - kubernetes

2. Checking Resources:
  ✓ No resources remaining in namespace

3. Checking APIServices:
  🔴 Found unavailable APIServices (these block namespace deletion):
    - v1alpha2.wgpolicyk8s.io
      Reason: MissingEndpoints
      Message: endpoints for service/kyverno-reports-server in "kyverno" have no addresses

4. Checking Webhooks:
  ✓ No problematic webhooks found

5. Known Issue Checks:
  🔴 Kyverno APIServices are unavailable (common blocker):
    - v1alpha2.wgpolicyk8s.io (False)

==========================================
Summary & Recommendations:
==========================================
🔴 PRIMARY ISSUE: Finalizers are blocking deletion
🔴 SECONDARY ISSUE: Unavailable APIServices are blocking deletion
```

## Quick Fix Commands

The script provides specific fix commands in the output. Common patterns:

```bash
# 1. Clear finalizers
kubectl get ns <ns> -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/<ns>/finalize" -f -

# 2. Delete broken APIServices
kubectl delete apiservice v1.reports.kyverno.io
kubectl delete apiservice v1alpha1.openreports.io
kubectl delete apiservice v1alpha2.wgpolicyk8s.io

# 3. Force delete all resources in namespace
kubectl delete all --all -n <ns> --force --grace-period=0
```

## Integration with Cleanup Script

After running the diagnostic, use the cleanup script:
```bash
# 1. Diagnose
./diagnose-terminating-namespaces.sh /path/to/kubeconfig

# 2. Fix based on findings
./kyverno-cleanup-fixed.sh /path/to/kubeconfig kyverno nirmata-kyverno-operator
```
