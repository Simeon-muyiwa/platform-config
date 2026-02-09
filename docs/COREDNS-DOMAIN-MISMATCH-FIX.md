# CoreDNS Domain Mismatch Fix

**Date**: February 6, 2026  
**Issue**: ArgoCD applications stuck in "Unknown" sync status  
**Root Cause**: CoreDNS and kubelet clusterDomain mismatch  
**Resolution**: Created Ansible playbook to permanently fix CoreDNS ConfigMap

## Key Deliverables

| File | Description |
|------|-------------|
| `ansible/playbooks/fix-coredns-domain.yml` | **Ansible playbook** - Automated, idempotent fix |
| `Makefile` target: `make fix-coredns` | One-command execution |
| `ansible/group_vars/all.yaml` | New `k8s_internal_domain` variable |
| `ansible/roles/kubeadm/templates/kubeadm-config.yaml.j2` | Template fix for new clusters |

---

## Table of Contents
1. [Problem Description](#problem-description)
2. [Symptoms](#symptoms)
3. [Root Cause Analysis](#root-cause-analysis)
4. [Solution](#solution)
5. [Prevention](#prevention)
6. [Quick Reference](#quick-reference)

---

## Problem Description

After deploying a fresh kubeadm cluster with ArgoCD, applications failed to sync with the following error:

```
Unable to sync platform-apps: error resolving repo revision: rpc error: code = Unavailable 
desc = connection error: desc = "transport: Error while dialing: dial tcp: lookup 
argocd-repo-server on 10.96.0.10:53: no such host"
```

The ArgoCD application controller couldn't resolve the `argocd-repo-server` service via DNS.

---

## Symptoms

1. **ArgoCD applications stuck in "Unknown" status**
2. **DNS lookups failing** for internal Kubernetes services
3. **Pods unable to communicate** with services by DNS name
4. **Error message**: `lookup <service-name> on 10.96.0.10:53: no such host`

---

## Root Cause Analysis

### The Mismatch

When investigating, we discovered a **mismatch between kubelet and CoreDNS configuration**:

**Kubelet Configuration** (`/var/lib/kubelet/config.yaml`):
```yaml
clusterDNS:
  - 10.96.0.10
clusterDomain: healthxcape.com  # <-- Uses external domain
```

**CoreDNS ConfigMap** (default):
```yaml
kubernetes cluster.local in-addr.arpa ip6.arpa {  # <-- Uses cluster.local
   pods insecure
   fallthrough in-addr.arpa ip6.arpa
   ttl 30
}
```

### How DNS Resolution Works

1. Pod created → kubelet injects `/etc/resolv.conf` based on its config
2. Pod's `/etc/resolv.conf` gets:
   ```
   search argocd.svc.healthxcape.com svc.healthxcape.com healthxcape.com
   nameserver 10.96.0.10
   ```
3. When pod looks up `argocd-repo-server`, it tries:
   - `argocd-repo-server.argocd.svc.healthxcape.com` ❌
   - `argocd-repo-server.svc.healthxcape.com` ❌
   - `argocd-repo-server.healthxcape.com` ❌
4. CoreDNS only knows about `*.cluster.local` → **No match!**

### Why This Happened

In our Ansible configuration, `cluster_domain` was used for both:
- External domain (certificates, ingress, OIDC URLs) → `healthxcape.com`
- Kubernetes internal domain (service DNS) → should be `cluster.local`

The kubeadm template used `cluster_domain` for `clusterDomain`, propagating the external domain into the cluster's internal DNS.

---

## Solution

### Primary Fix: Ansible Playbook

We created a dedicated Ansible playbook that:
1. ✅ Detects if fix is needed (idempotent)
2. ✅ Updates CoreDNS ConfigMap to use the correct domain
3. ✅ Restarts CoreDNS pods automatically
4. ✅ Waits for pods to be ready
5. ✅ Verifies DNS resolution works

**Playbook Location**: `ansible/playbooks/fix-coredns-domain.yml`

**Run with:**
```bash
make fix-coredns
# or
ansible-playbook -i ansible/hosts.ini ansible/playbooks/fix-coredns-domain.yml
```

**Playbook Output:**
```
TASK [Display fix information]
ok: [master-10-1-0-10] => {
    "msg": "🔧 Fixing CoreDNS Domain Mismatch\n\n
           Issue: kubelet uses clusterDomain=healthxcape.com\n
           but CoreDNS was configured for cluster.local"
}

TASK [Update CoreDNS ConfigMap with correct domain]
changed: [master-10-1-0-10]

TASK [Restart CoreDNS pods to pick up new config]
changed: [master-10-1-0-10]

PLAY RECAP
master-10-1-0-10: ok=9  changed=2  failed=0
```

### Alternative: Manual Fix (if needed)
```bash
# SSH to master node
kubectl edit configmap coredns -n kube-system

# Change this line:
#   kubernetes cluster.local in-addr.arpa ip6.arpa {
# To:
#   kubernetes healthxcape.com in-addr.arpa ip6.arpa {

# Then restart CoreDNS
kubectl delete pod -n kube-system -l k8s-app=kube-dns
```

### Permanent Fix: Updated Ansible Configuration

**1. New variable in `ansible/group_vars/all.yaml`:**
```yaml
# Domain Configuration
# - cluster_domain: External domain for ingress, certificates, OIDC URLs
# - k8s_internal_domain: Kubernetes internal DNS domain for pod/service resolution
cluster_domain: "{{ ansible_inventory.cluster.domain | default('healthxcape.com') }}"
k8s_internal_domain: "{{ cluster_domain }}"  # Set to match existing clusters
dns_domain: "{{ k8s_internal_domain }}"
```

**2. Updated `ansible/roles/kubeadm/templates/kubeadm-config.yaml.j2`:**
```yaml
# DNS and domain configuration
clusterDNS:
  - "10.96.0.10"
clusterDomain: "{{ k8s_internal_domain | default('cluster.local') }}"
```

---

## Prevention

### For New Clusters

You have two options:

**Option A: Use standard `cluster.local` (Recommended for new clusters)**
```yaml
# group_vars/all.yaml
cluster_domain: "healthxcape.com"        # External domain
k8s_internal_domain: "cluster.local"     # Standard K8s internal domain
```

**Option B: Use external domain (Current setup, requires CoreDNS patch)**
```yaml
# group_vars/all.yaml  
cluster_domain: "healthxcape.com"
k8s_internal_domain: "{{ cluster_domain }}"  # Uses healthxcape.com internally
```

If using Option B, the CoreDNS fix must be applied after cluster creation:
```bash
make fix-coredns
```

### After kubeadm Upgrades

⚠️ **Warning**: `kubeadm upgrade` may reset CoreDNS to default `cluster.local`. 

Add to your upgrade runbook:
```bash
# After kubeadm upgrade
make fix-coredns
```

---

## Quick Reference

### Diagnose the Issue

```bash
# Check kubelet's clusterDomain
cat /var/lib/kubelet/config.yaml | grep clusterDomain

# Check CoreDNS configuration
kubectl get configmap coredns -n kube-system -o yaml | grep kubernetes

# Check pod's DNS config
kubectl exec -n argocd <pod-name> -- cat /etc/resolv.conf

# Test DNS resolution from a pod
kubectl run dns-test --rm -it --restart=Never --image=busybox:1.36 -- \
  nslookup kubernetes.default.svc.healthxcape.com
```

### Fix Commands

```bash
# Automated fix
make fix-coredns

# Manual verification after fix
kubectl get application -n argocd
```

### Files Modified

| File | Purpose |
|------|---------|
| `ansible/playbooks/fix-coredns-domain.yml` | Playbook to patch CoreDNS |
| `ansible/group_vars/all.yaml` | Added `k8s_internal_domain` variable |
| `ansible/roles/kubeadm/templates/kubeadm-config.yaml.j2` | Uses `k8s_internal_domain` |
| `Makefile` | Added `fix-coredns` target |

---

## Related Issues

- ArgoCD sync failures
- Service-to-service communication failures
- Helm chart deployments failing to resolve dependencies
- Any pod-to-pod DNS resolution issues

---

## References

- [Kubernetes DNS Specification](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
- [CoreDNS Kubernetes Plugin](https://coredns.io/plugins/kubernetes/)
- [kubeadm ClusterConfiguration](https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta3/)
