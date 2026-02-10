# Cluster Logs Review Guide - Namespace Termination Issues

## Overview

When **every newly created namespace** gets stuck in Terminating, this indicates a **cluster-wide infrastructure problem**. Review these logs in order of priority.

---

## 🔴 Priority 1: API Server Logs (Most Critical)

### Where to Find Logs

**If API server runs as a pod:**
```bash
# List API server pods
kubectl get pods -n kube-system -l component=kube-apiserver

# Get logs
kubectl logs -n kube-system <apiserver-pod-name> --tail=1000

# Follow logs
kubectl logs -n kube-system <apiserver-pod-name> -f
```

**If API server runs as a static pod (on master node):**
```bash
# SSH to master node
ssh <master-node>

# View logs
journalctl -u kube-apiserver -n 1000 --no-pager
# Or
tail -f /var/log/kube-apiserver.log
```

### What to Look For

#### 1. APIService Errors
```
# Look for:
- "service unavailable"
- "503 Service Unavailable"
- "MissingEndpoints"
- "Failed to get endpoints"
- "no endpoints available"
```

**Example:**
```
E0204 15:01:52.179192 apiserver.go:132] "HTTP" resp=503 
statusStack=<...> logging error output: "service unavailable\n"
```

#### 2. Timeout Errors
```
# Look for:
- "timeout"
- "context deadline exceeded"
- "request timeout"
- "slow request"
```

#### 3. etcd Connection Issues
```
# Look for:
- "etcdserver: request timed out"
- "etcd: connection refused"
- "etcd: no leader"
- "etcd: client: etcd cluster is unavailable"
```

#### 4. Resource Enumeration Failures
```
# Look for:
- "failed to list"
- "unable to retrieve the complete list"
- "error listing"
```

#### 5. Webhook Failures
```
# Look for:
- "webhook timeout"
- "webhook error"
- "admission webhook"
```

### Key Commands

```bash
# Check for APIService errors
kubectl logs -n kube-system <apiserver-pod> | grep -i "apiservice\|503\|service unavailable"

# Check for timeout errors
kubectl logs -n kube-system <apiserver-pod> | grep -i "timeout\|deadline"

# Check for etcd errors
kubectl logs -n kube-system <apiserver-pod> | grep -i "etcd"

# Check for webhook errors
kubectl logs -n kube-system <apiserver-pod> | grep -i "webhook"
```

---

## 🔴 Priority 2: Controller Manager Logs

### Where to Find Logs

```bash
# List controller manager pods
kubectl get pods -n kube-system -l component=kube-controller-manager

# Get logs
kubectl logs -n kube-system <controller-manager-pod> --tail=1000

# On master node (if static pod)
journalctl -u kube-controller-manager -n 1000 --no-pager
```

### What to Look For

#### 1. Namespace Controller Errors
```
# Look for:
- "error syncing namespace"
- "failed to delete namespace"
- "namespace deletion failed"
- "error processing namespace"
```

#### 2. Finalizer Issues
```
# Look for:
- "finalizer"
- "unable to remove finalizer"
- "finalizer removal failed"
```

#### 3. Resource Cleanup Failures
```
# Look for:
- "failed to delete"
- "error deleting"
- "cleanup failed"
```

#### 4. APIService Issues
```
# Look for:
- "apiservice"
- "aggregated api"
- "unable to list"
```

### Key Commands

```bash
# Check for namespace-related errors
kubectl logs -n kube-system <controller-manager-pod> | grep -i "namespace"

# Check for finalizer errors
kubectl logs -n kube-system <controller-manager-pod> | grep -i "finalizer"

# Check for deletion errors
kubectl logs -n kube-system <controller-manager-pod> | grep -i "delete\|cleanup"
```

---

## 🟠 Priority 3: etcd Logs

### Where to Find Logs

**If etcd runs as a pod:**
```bash
kubectl logs -n kube-system <etcd-pod> --tail=1000
```

**If etcd runs as a static pod (most common):**
```bash
# SSH to master node
ssh <master-node>

# View logs
journalctl -u etcd -n 1000 --no-pager
# Or
tail -f /var/log/etcd.log
```

### What to Look For

#### 1. Performance Issues
```
# Look for:
- "slow request"
- "took too long"
- "timeout"
- "read index timeout"
```

#### 2. Connection Issues
```
# Look for:
- "connection refused"
- "connection reset"
- "network error"
```

#### 3. Leader Election Issues
```
# Look for:
- "no leader"
- "leader election"
- "election timeout"
```

#### 4. Disk Issues
```
# Look for:
- "no space left"
- "disk full"
- "write error"
- "I/O error"
```

### Key Commands

```bash
# Check for slow requests
journalctl -u etcd | grep -i "slow\|timeout"

# Check for connection errors
journalctl -u etcd | grep -i "connection\|network"

# Check for disk errors
journalctl -u etcd | grep -i "disk\|space\|I/O"
```

---

## 🟠 Priority 4: Container Runtime Logs (containerd/docker)

### Where to Find Logs

**containerd:**
```bash
# On worker nodes
journalctl -u containerd -n 1000 --no-pager

# Or
tail -f /var/log/containerd.log
```

**Docker:**
```bash
journalctl -u docker -n 1000 --no-pager
# Or
tail -f /var/log/docker.log
```

### What to Look For

#### 1. Container Deletion Failures
```
# Look for:
- "failed to delete container"
- "error removing container"
- "stop container failed"
- "kill container failed"
```

#### 2. Timeout Issues
```
# Look for:
- "timeout"
- "context deadline exceeded"
- "operation timeout"
```

#### 3. Resource Issues
```
# Look for:
- "OOM" (Out of Memory)
- "no space left"
- "resource exhausted"
```

### Key Commands

```bash
# Check for deletion errors
journalctl -u containerd | grep -i "delete\|remove\|stop\|kill"

# Check for timeouts
journalctl -u containerd | grep -i "timeout"

# Check for OOM kills
journalctl -u containerd | grep -i "OOM\|out of memory"
```

---

## 🟡 Priority 5: Kubelet Logs

### Where to Find Logs

```bash
# SSH to node
ssh <node-name>

# View logs
journalctl -u kubelet -n 1000 --no-pager
# Or
tail -f /var/log/kubelet.log
```

### What to Look For

#### 1. Pod Deletion Issues
```
# Look for:
- "failed to delete pod"
- "error killing pod"
- "pod deletion failed"
```

#### 2. Container Runtime Issues
```
# Look for:
- "container runtime"
- "failed to stop container"
- "runtime error"
```

#### 3. Network Issues
```
# Look for:
- "network plugin"
- "CNI error"
- "network setup failed"
```

### Key Commands

```bash
# Check for pod deletion errors
journalctl -u kubelet | grep -i "delete\|kill\|stop"

# Check for container runtime errors
journalctl -u kubelet | grep -i "container\|runtime"
```

---

## 🟡 Priority 6: CNI/Network Plugin Logs

### Where to Find Logs

**Calico:**
```bash
kubectl logs -n kube-system -l k8s-app=calico-node --tail=1000
```

**Flannel:**
```bash
kubectl logs -n kube-system -l app=flannel --tail=1000
```

**Cilium:**
```bash
kubectl logs -n kube-system -l k8s-app=cilium --tail=1000
```

### What to Look For

#### 1. Network Setup Failures
```
# Look for:
- "failed to setup network"
- "network plugin error"
- "CNI error"
```

#### 2. IP Allocation Issues
```
# Look for:
- "IP allocation failed"
- "no IPs available"
- "IPAM error"
```

---

## 🔍 Comprehensive Log Review Script

### Quick Log Check

```bash
#!/bin/bash
# Run on master node

echo "=== API Server Logs (Last 50 errors) ==="
journalctl -u kube-apiserver -n 1000 --no-pager | grep -i "error\|failed\|503" | tail -50

echo ""
echo "=== Controller Manager Logs (Last 50 errors) ==="
journalctl -u kube-controller-manager -n 1000 --no-pager | grep -i "error\|failed\|namespace" | tail -50

echo ""
echo "=== etcd Logs (Last 50 errors) ==="
journalctl -u etcd -n 1000 --no-pager | grep -i "error\|failed\|slow\|timeout" | tail -50

echo ""
echo "=== containerd Logs (Last 50 errors) ==="
journalctl -u containerd -n 1000 --no-pager | grep -i "error\|failed\|timeout" | tail -50

echo ""
echo "=== Kubelet Logs (Last 50 errors) ==="
journalctl -u kubelet -n 1000 --no-pager | grep -i "error\|failed\|delete" | tail -50
```

---

## 📋 Log Review Checklist

### For Namespace Termination Issues

- [ ] **API Server:**
  - [ ] Check for APIService errors (503, service unavailable)
  - [ ] Check for timeout errors
  - [ ] Check for etcd connection issues
  - [ ] Check for webhook failures

- [ ] **Controller Manager:**
  - [ ] Check for namespace controller errors
  - [ ] Check for finalizer removal failures
  - [ ] Check for resource cleanup errors

- [ ] **etcd:**
  - [ ] Check for slow requests
  - [ ] Check for connection issues
  - [ ] Check for disk space issues

- [ ] **Container Runtime:**
  - [ ] Check for container deletion failures
  - [ ] Check for timeout issues
  - [ ] Check for OOM kills

- [ ] **Kubelet:**
  - [ ] Check for pod deletion failures
  - [ ] Check for container runtime errors

---

## 🎯 Most Common Issues Found in Logs

### Issue 1: APIService Unavailable
**Log Pattern:**
```
apiserver: "HTTP" resp=503 statusStack=... "service unavailable"
```

**Fix:**
```bash
kubectl get apiservices | grep -v "True"
kubectl delete apiservice <broken-apiservice>
```

### Issue 2: etcd Slow/Timeout
**Log Pattern:**
```
etcd: "read index timeout"
etcd: "took too long"
```

**Fix:**
- Check etcd disk I/O
- Check etcd disk space
- Check network latency to etcd

### Issue 3: Controller Manager Can't Process
**Log Pattern:**
```
controller-manager: "error syncing namespace"
controller-manager: "failed to delete namespace"
```

**Fix:**
- Check controller manager pod is running
- Check controller manager has resources
- Check for finalizer issues

### Issue 4: Container Runtime Issues
**Log Pattern:**
```
containerd: "failed to delete container"
containerd: "timeout"
```

**Fix:**
- Check container runtime health
- Check node resources
- Restart container runtime if needed

---

## 🔧 Automated Log Collection

### Collect All Relevant Logs

```bash
#!/bin/bash
# collect-logs.sh

OUTPUT_DIR="./cluster-logs-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTPUT_DIR"

echo "Collecting cluster logs to $OUTPUT_DIR..."

# API Server
kubectl logs -n kube-system -l component=kube-apiserver --tail=5000 > "$OUTPUT_DIR/apiserver.log" 2>&1

# Controller Manager
kubectl logs -n kube-system -l component=kube-controller-manager --tail=5000 > "$OUTPUT_DIR/controller-manager.log" 2>&1

# etcd (if pod)
kubectl logs -n kube-system -l component=etcd --tail=5000 > "$OUTPUT_DIR/etcd.log" 2>&1

# Scheduler
kubectl logs -n kube-system -l component=kube-scheduler --tail=5000 > "$OUTPUT_DIR/scheduler.log" 2>&1

# APIServices status
kubectl get apiservices -o yaml > "$OUTPUT_DIR/apiservices.yaml" 2>&1

# Webhooks
kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations -o yaml > "$OUTPUT_DIR/webhooks.yaml" 2>&1

# Stuck namespaces
kubectl get ns -o yaml > "$OUTPUT_DIR/namespaces.yaml" 2>&1

echo "Logs collected in $OUTPUT_DIR"
```

---

## 📊 Log Analysis Tips

### 1. Look for Patterns
- Multiple errors of the same type
- Errors occurring at the same time
- Errors correlating with namespace deletion attempts

### 2. Check Timestamps
- Compare error timestamps with namespace deletion timestamps
- Look for errors just before namespace gets stuck

### 3. Check Error Frequency
- High frequency errors indicate systemic issues
- Occasional errors might be transient

### 4. Correlate Across Components
- API server errors + Controller manager errors = systemic issue
- etcd errors + API server errors = etcd problem affecting API server

---

## 🚨 Critical Log Patterns to Watch

### Pattern 1: APIService Chain Failure
```
apiserver: "service unavailable" → 
controller-manager: "unable to list resources" → 
namespace: stuck in Terminating
```

### Pattern 2: etcd Performance
```
etcd: "slow request" → 
apiserver: "timeout" → 
controller-manager: "failed to sync" → 
namespace: stuck in Terminating
```

### Pattern 3: Resource Cleanup Failure
```
controller-manager: "failed to delete resource" → 
namespace: stuck in Terminating
```

---

## Summary

**For cluster-wide namespace termination issues, review logs in this order:**

1. **API Server** - Check for APIService errors, timeouts, etcd issues
2. **Controller Manager** - Check for namespace controller errors
3. **etcd** - Check for performance/connection issues
4. **Container Runtime** - Check for container deletion failures
5. **Kubelet** - Check for pod deletion failures

**Most common root cause:** Unavailable APIServices blocking resource enumeration during namespace deletion.
