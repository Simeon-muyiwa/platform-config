# Complete Session Workflow Documentation
## GitOps Platform Deployment on Air-Gapped Kubernetes Cluster

**Date**: January 13, 2026  
**Platform**: kubeadm v1.29.0 on AWS EC2  
**Domain**: healthxcape.com  
**ArgoCD**: v2.13.3  

---

## Table of Contents
1. [Architecture Overview](#architecture-overview)
2. [Infrastructure Details](#infrastructure-details)
3. [Session Workflow](#session-workflow)
4. [Issues Encountered & Solutions](#issues-encountered--solutions)
5. [Manual Fixes Requiring Source Code Updates](#manual-fixes-requiring-source-code-updates)
6. [Image Distribution Process](#image-distribution-process)
7. [GitOps Configuration](#gitops-configuration)
8. [Ingress & Routing Configuration](#ingress--routing-configuration)
9. [Key Learnings](#key-learnings)
10. [Quick Reference Commands](#quick-reference-commands)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           GitOps Architecture                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  GitHub (platform-config repo)                                               │
│         │                                                                    │
│         ▼                                                                    │
│  ┌─────────────┐     ┌──────────────────┐     ┌────────────────────┐        │
│  │   ArgoCD    │────▶│  webapp-operator │────▶│  Kubernetes        │        │
│  │  (GitOps)   │     │  (Custom CRDs)   │     │  Resources         │        │
│  └─────────────┘     └──────────────────┘     └────────────────────┘        │
│                                                                              │
│  CRDs: Frontend, IdentityService, UserService, BlogService                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Components Deployed
- **Frontend**: Next.js 15 app with sign-in/sign-up/profile pages
- **Identity Service**: NestJS auth service with JWT, PostgreSQL, Redis
- **User Service**: NestJS user profiles with PostgreSQL
- **Blog Service**: NestJS blog posts with PostgreSQL
- **webapp-operator**: Custom Kubernetes operator managing service CRDs

---

## Infrastructure Details

### Nodes
| Role | Private IP | Public IP | Notes |
|------|------------|-----------|-------|
| Master | 10.1.0.10 | 13.41.15.144 (EIP) | Has internet access, buildkit installed |
| Worker | 10.1.91.144 | N/A | **AIR-GAPPED** - No internet access |
| Bastion | N/A | 18.132.222.72 | Jump host for SSH |

### Access Credentials
- **ArgoCD URL**: https://argocd.healthxcape.com
- **ArgoCD Credentials**: admin / `Wa6SV9XmgNmaeii9`
- **Frontend URL**: https://healthxcape.com

### SSH Access Pattern
```bash
# Local → Bastion
ssh -i ~/.ssh/bastion-key ubuntu@18.132.222.72

# Bastion → Master
ssh ubuntu@10.1.0.10

# Bastion → Worker
ssh ubuntu@10.1.91.144
```

---

## Session Workflow

### Phase 1: ArgoCD Setup with TLS (Completed Previously)
- ArgoCD deployed with DNS-01 TLS certificates via Let's Encrypt
- OIDC discovery endpoint configured
- Applications created: webapp-operator, platform-apps, platform-services, kafka-cluster

### Phase 2: Fix Base CR Files for Kustomize Override

**Problem**: Base CR files had hardcoded ECR URLs that kustomize couldn't override.

**Before** (didn't work with kustomize):
```yaml
image: 939217651725.dkr.ecr.eu-west-2.amazonaws.com/kubeadm_ec2_cluster/frontend:latest
```

**After** (works with kustomize):
```yaml
image: healthxcape/frontend:v1.0.0
```

**Files Changed**:
- `platform-config/base/frontend/frontend.yaml`
- `platform-config/base/identity-service/identityservice.yaml`
- `platform-config/base/user-service/userservice.yaml`
- `platform-config/base/blog-service/blogservice.yaml`

**Commit**: `e9170df` - "Fix: Use simple image names for kustomize override in base CRs"

### Phase 3: Fix Kafka Topics Schema

**Problem**: CRD expected `kafka.topics` as object, but YAML had array.

**Error**:
```
ValidationError: kafka.topics must be object, got array
```

**Before** (incorrect):
```yaml
kafka:
  topics:
    - "identity.events"
    - "user.events"
```

**After** (correct):
```yaml
kafka:
  topics:
    identityEvents: "identity.events"
    userEvents: "user.events"
```

**Commit**: `5c89493` - "Fix: Update kafka.topics to match CRD schema"

### Phase 4: Remove Worker Node Taint

**Problem**: Worker node had taint preventing pod scheduling.

**Command**:
```bash
kubectl taint nodes ip-10-1-91-144 node.cloudprovider.kubernetes.io/uninitialized:NoSchedule-
```

⚠️ **TODO**: This should be fixed in the CCM (Cloud Controller Manager) configuration or node bootstrap.

### Phase 5: Build and Distribute Service Images

**Problem**: Worker node is air-gapped, can't pull images from internet.

**Solution**: Build on master → save to tarball → scp via bastion → load on worker

#### Images Built and Distributed:

| Image | Tag | Size | Source |
|-------|-----|------|--------|
| healthxcape/frontend | v1.0.1 | 87MB | microservices-platform/services/frontend |
| healthxcape/identity-service | v1.0.0 | 67MB | microservices-platform/services/identity-service |
| healthxcape/user-service | v1.0.0 | 65MB | microservices-platform/services/user-service |
| healthxcape/blog-service | v1.0.0 | 65MB | microservices-platform/services/blog-service |
| postgres | 15-alpine | ~80MB | Docker Hub (pulled on master) |
| redis | 7-alpine | ~40MB | Docker Hub (pulled on master) |

### Phase 6: Setup Storage for PostgreSQL

**Problem**: PostgreSQL StatefulSets couldn't start - PVCs unbound.

**Solution**: Created local-storage StorageClass and PersistentVolumes.

```yaml
# StorageClass
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer

# PersistentVolumes (created for each service)
apiVersion: v1
kind: PersistentVolume
metadata:
  name: identity-postgres-pv
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  storageClassName: local-storage
  local:
    path: /mnt/data/identity-postgres
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ip-10-1-91-144
```

⚠️ **TODO**: This should be automated in Ansible/Pulumi or use a dynamic provisioner like local-path-provisioner.

### Phase 7: Fix Wrong Frontend Image

**Problem**: Initially built the wrong frontend (simple Express webapp instead of Next.js).

**Wrong source**: `microservices-platform/webapp/` (returns JSON)
**Correct source**: `microservices-platform/services/frontend/` (Next.js with auth)

**Discovery**: When testing, got JSON instead of HTML:
```json
{"message":"Hello from Simple WebApp!","hostname":"frontend-xxx"}
```

**Solution**: Rebuilt from correct source and distributed as `v1.0.1`.

### Phase 8: Fix Health Check Path

**Problem**: Next.js app doesn't have `/health` endpoint, causing liveness probe failures.

**Error**:
```
Liveness probe failed: HTTP probe failed with statuscode: 404
```

**Solution**: Updated health check path from `/health` to `/` in base CR.

**File**: `platform-config/base/frontend/frontend.yaml`
```yaml
healthCheck:
  path: /
  port: 3000
```

### Phase 9: GitOps Image Update

**Problem**: Manual kubectl patches were being overwritten by operator reconciliation.

**Realization**: Changes must go through Git for GitOps to work properly!

**Final commit**: `4de9591` - "Fix: Update frontend CR to use v1.0.1 image with Next.js app"

---

## Additional Issues Encountered During Session

### Issue 6: Created Ingress for Auth Subdomain (Manual)

**What we did**: Created an ingress for `auth.healthxcape.com` to route to auth-frontend service.

```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: auth-frontend
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - auth.healthxcape.com
    secretName: auth-frontend-tls
  rules:
  - host: auth.healthxcape.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: auth-frontend
            port:
              number: 3000
EOF
```

**Also patched main ingress** to add `/auth` path:
```bash
kubectl patch ingress frontend -n default --type=json \
  -p='[{"op": "add", "path": "/spec/rules/0/http/paths/-", "value": {"path": "/auth", "pathType": "Prefix", "backend": {"service": {"name": "auth-frontend", "port": {"number": 3000}}}}}]'
```

⚠️ **TODO**: Add this ingress to `platform-config/base/frontend/` or create dedicated ingress resources.

---

### Issue 7: Built WRONG Frontend Initially

**Critical Discovery**: We initially built from the wrong source directory!

**Wrong source** (simple Express webapp):
```
/Users/simeon/Desktop/IAC/Pulumi_project/microservices-platform/webapp/
```

This returned JSON:
```json
{"message":"Hello from Simple WebApp!","hostname":"frontend-xxx","version":"1.0.0"}
```

**Correct source** (Next.js with auth pages):
```
/Users/simeon/Desktop/IAC/Pulumi_project/microservices-platform/services/frontend/
```

This has proper pages: `/sign-in`, `/sign-up`, `/profile`, `/coffees`

**How we discovered**: When curling the frontend, we got JSON instead of HTML:
```bash
curl -k -s https://healthxcape.com/
# Returned: {"message":"Hello from Simple WebApp!"}
```

**Solution**: Rebuilt from correct `services/frontend/` directory.

---

### Issue 8: Image Tag Collision on Worker Node

**Problem**: After building new frontend, worker still used old image.

**Discovery**:
```bash
# Master had new image (271 MB - Next.js)
sudo nerdctl images | grep frontend
# healthxcape/frontend  v1.0.0  d22dbb978cb7  271.6 MiB

# Worker had old image (150 MB - Express)
sudo nerdctl -n k8s.io images | grep frontend
# healthxcape/frontend  v1.0.0  4379064657ef  150.8 MiB
```

Same tag, different SHA! Containerd used cached version.

**Attempted fix** (failed):
```bash
sudo nerdctl -n k8s.io rmi healthxcape/frontend:v1.0.0 --force
# Error: image is being used by running container
```

**Working solution**: Use different tag `v1.0.1`:
```bash
# On master
sudo nerdctl tag healthxcape/frontend:v1.0.0 healthxcape/frontend:v1.0.1
sudo nerdctl save healthxcape/frontend:v1.0.1 > /tmp/frontend-v101.tar

# Distribute to worker
scp /tmp/frontend-v101.tar ubuntu@10.1.91.144:/tmp/
ssh ubuntu@10.1.91.144 'sudo nerdctl -n k8s.io load < /tmp/frontend-v101.tar'
```

---

### Issue 9: Health Check Probe Failures

**Error in pod describe**:
```
Warning  Unhealthy  41s  kubelet  Readiness probe failed: HTTP probe failed with statuscode: 404
Warning  Unhealthy  11s  kubelet  Liveness probe failed: HTTP probe failed with statuscode: 404
```

**Root cause**: Operator creates deployments with `/health` probe path, but Next.js app doesn't have that route.

**Manual fix** (temporary):
```bash
kubectl patch deployment frontend -n default --type=json \
  -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/httpGet/path", "value": "/"}, {"op": "replace", "path": "/spec/template/spec/containers/0/readinessProbe/httpGet/path", "value": "/"}]'
```

**Proper fix** (in Git): Updated `platform-config/base/frontend/frontend.yaml`:
```yaml
healthCheck:
  path: /
  port: 3000
```

---

### Issue 10: auth-frontend-deployment Not Updating

**Problem**: After updating `frontend` deployment, `auth-frontend-deployment` still used old `v1.0.0` image.

**Discovery**:
```bash
kubectl get pods -l app=frontend -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image

# auth-frontend-deployment-xxx   healthxcape/frontend:v1.0.0  ← OLD!
# frontend-xxx                   healthxcape/frontend:v1.0.1  ← NEW
```

**Root cause**: The operator manages `auth-frontend-deployment` from the Frontend CR, and we only patched `frontend` deployment manually.

**Manual fix** (temporary):
```bash
kubectl set image deployment/auth-frontend-deployment frontend=healthxcape/frontend:v1.0.1 -n default
```

**Proper fix**: Updated the base CR in Git and pushed - operator then reconciled.

---

### Issue 11: User Reminder About GitOps

**User's key insight**: 
> "do we not need to push to github for change to occur since we are using rules.json, overlay etc as configuration as code"

This reminded us that all our manual `kubectl` patches were wrong approach. We needed to:

1. Update the source YAML in `platform-config/`
2. Commit and push to GitHub
3. Let ArgoCD sync the changes

**Lesson**: In GitOps, the Git repository is the source of truth, not `kubectl`.

---

### Issue 12: Deleting Old Frontend Pods

**Problem**: Old pods with wrong image kept serving traffic.

**Command used**:
```bash
kubectl delete pods -n default -l app=frontend --force --grace-period=0
```

**Then removed old image on worker** (after pods deleted):
```bash
# This failed while containers running:
sudo nerdctl -n k8s.io rmi healthxcape/frontend:v1.0.0 --force
# Error: image is being used by running container

# Had to delete pods first, then image could be removed
```

---

## Issues Encountered & Solutions

### Issue 1: Kustomize Image Override Not Working

**Symptom**: Images in overlay weren't being applied to CRs.

**Root Cause**: Kustomize `images` transformers only work on native Kubernetes resources (Deployment, Pod, etc.), not Custom Resources. They look for well-known fields like `spec.containers[].image`.

**Initial Solution** (what we did): Update image directly in base CR files.

**Better Solutions** (for proper GitOps):

1. **Strategic Merge Patches** (recommended):
```yaml
# overlays/dev/kustomization.yaml
patchesStrategicMerge:
  - patches/frontend-image.yaml

# overlays/dev/patches/frontend-image.yaml
apiVersion: apps.example.com/v1alpha1
kind: Frontend
metadata:
  name: auth-frontend
spec:
  image: healthxcape/frontend:v1.0.1
```

2. **JSON Patches**:
```yaml
# overlays/dev/kustomization.yaml
patches:
  - target:
      kind: Frontend
      name: auth-frontend
    patch: |-
      - op: replace
        path: /spec/image
        value: healthxcape/frontend:v1.0.1
```

3. **Replacements + ConfigMapGenerator** (most elegant for GitOps Coordinator):
```yaml
# overlays/dev/kustomization.yaml
configMapGenerator:
  - name: image-versions
    literals:
      - frontend=healthxcape/frontend:v1.0.1
      - identity=healthxcape/identity-service:v1.0.0
    options:
      disableNameSuffixHash: true

replacements:
  - source:
      kind: ConfigMap
      name: image-versions
      fieldPath: data.frontend
    targets:
      - select:
          kind: Frontend
        fieldPaths:
          - spec.image
```

**Lesson**: For CRDs, use patches or replacements - the `images` transformer is only for native K8s resources. The ConfigMapGenerator + replacements pattern is ideal for GitOps Coordinator to update a single source file.

**TODO**: Refactor platform-config to use Option 3 (ConfigMapGenerator + replacements) so GitOps Coordinator only updates the ConfigMap literals.

---

### Issue 2: Old ReplicaSets Keep Respawning

**Symptom**: After image update, old pods with wrong image kept appearing.

**Root Cause**: Two ReplicaSets existed - old one with ECR image, new one with correct image.

**Solution**: Delete old ReplicaSet manually:
```bash
kubectl delete rs <old-replicaset-name> --cascade=foreground
```

**Lesson**: When operator manages resources, ensure clean transitions.

---

### Issue 3: Image Tag Collision

**Symptom**: New image not loading on worker despite `nerdctl load`.

**Root Cause**: Same tag (`v1.0.0`) existed with old image SHA, containerd used cached version.

**Solution**: Use different tag (`v1.0.1`) for new image:
```bash
# On master
sudo nerdctl tag healthxcape/frontend:v1.0.0 healthxcape/frontend:v1.0.1
sudo nerdctl save healthxcape/frontend:v1.0.1 > /tmp/frontend-v101.tar

# Transfer and load on worker
sudo nerdctl -n k8s.io load < /tmp/frontend-v101.tar
```

**Lesson**: Always use unique tags, never reuse tags for different builds.

---

### Issue 4: Service Selector Mismatch

**Symptom**: Ingress routing to wrong pods.

**Root Cause**: Both `frontend` and `auth-frontend-deployment` had `app: frontend` label.

**Solution**: Ensured all pods with same label have same image version.

**TODO**: Consider using more specific selectors in the operator.

---

### Issue 5: Kafka Connection Errors (Expected)

**Symptom**: Services show Kafka connection errors in logs.

**Error**:
```
Connection error: getaddrinfo ENOTFOUND my-cluster-kafka-bootstrap.kafka
```

**Status**: Expected - Kafka not deployed yet. Services continue running with degraded functionality.

**Solution**: Deploy Strimzi Kafka cluster when ready.

---

## Manual Fixes Requiring Source Code Updates

These fixes were done via kubectl but need to be codified:

### 1. Worker Node Taint Removal
**Current**: Manual `kubectl taint` command
**TODO**: Fix in CCM configuration or Ansible playbook

**Location**: `ansible/playbooks/deploy-aws-ccm.yml` or node bootstrap

### 2. Storage Provisioning
**Current**: Manual PV/StorageClass creation
**TODO**: Add to platform-config or use dynamic provisioner

**Options**:
- Add StorageClass and PVs to `platform-config/base/storage/`
- Deploy local-path-provisioner
- Use EBS CSI driver with proper IRSA

### 3. Health Check Paths in Operator
**Current**: Operator creates deployments with `/health` probe
**TODO**: Update operator to read `healthCheck.path` from CR

**Location**: `microservices-platform/operator/controllers/`

### 4. Image Pull Policy
**Current**: Some deployments have `imagePullPolicy: Always` which fails on air-gapped worker
**TODO**: Operator should set `imagePullPolicy: Never` or `IfNotPresent` for air-gapped environments

### 5. Auth Subdomain Ingress
**Current**: Created manually via `kubectl apply`
**TODO**: Add `auth-frontend-ingress.yaml` to `platform-config/base/frontend/`

### 6. DNS Record for auth.healthxcape.com
**Current**: Not created - auth subdomain doesn't resolve
**TODO**: Add A record in Route53: `auth.healthxcape.com → 13.41.15.144`

---

## Ingress & Routing Configuration

### Current Ingress Setup

| Host | Path | Service | Port | TLS |
|------|------|---------|------|-----|
| healthxcape.com | / | frontend | 80 | ✅ letsencrypt-prod |
| www.healthxcape.com | / | frontend | 80 | ✅ letsencrypt-prod |
| argocd.healthxcape.com | / | argocd-server | 443 | ✅ letsencrypt-prod |
| oidc.healthxcape.com | / | (static files) | 80 | ✅ letsencrypt-prod |
| auth.healthxcape.com | / | auth-frontend | 3000 | ✅ (created manually) |

### Services Exposed via NodePort (Backend APIs)

| Service | ClusterIP | NodePort | Internal DNS |
|---------|-----------|----------|--------------|
| identity-service | 10.100.93.180 | 30083 | identity-service:3000 |
| user-service | 10.110.2.85 | 30084 | user-service:3001 |
| blog-service | 10.96.147.57 | 30085 | blog-service:3002 |
| auth-frontend | 10.99.179.241 | 30082 | auth-frontend:3000 |

### How Frontend Calls Backend APIs

The frontend uses **server-side actions** to call backend services via internal Kubernetes DNS:

```typescript
// app/(auth)/sign-in/actions.tsx
const API_URL = process.env.IDENTITY_API_URL || 'http://identity-service:3000';

const response = await fetch(`${API_URL}/identity/sign-in`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ email, password }),
});
```

This works because:
1. Next.js server actions run on the server (pod)
2. Pod can resolve `identity-service` via Kubernetes DNS
3. No need to expose APIs publicly

---

## Image Distribution Process

### Standard Workflow for Air-Gapped Deployment

```bash
# 1. Build image on master (has internet)
ssh -i ~/.ssh/bastion-key ubuntu@18.132.222.72 \
  "ssh ubuntu@10.1.0.10 'cd /path/to/source && sudo nerdctl build -t image:tag .'"

# 2. Save to tarball
ssh -i ~/.ssh/bastion-key ubuntu@18.132.222.72 \
  "ssh ubuntu@10.1.0.10 'sudo nerdctl save image:tag > /tmp/image.tar'"

# 3. Copy via bastion
ssh -i ~/.ssh/bastion-key ubuntu@18.132.222.72 \
  "scp ubuntu@10.1.0.10:/tmp/image.tar /tmp/ && scp /tmp/image.tar ubuntu@10.1.91.144:/tmp/"

# 4. Load on worker
ssh -i ~/.ssh/bastion-key ubuntu@18.132.222.72 \
  "ssh ubuntu@10.1.91.144 'sudo nerdctl -n k8s.io load < /tmp/image.tar'"
```

### Copying Source Code to Master

```bash
# 1. Create tarball locally (exclude node_modules)
cd /path/to/service
tar --exclude='node_modules' --exclude='.next' -czf /tmp/service.tar.gz .

# 2. Copy via bastion
scp -i ~/.ssh/bastion-key /tmp/service.tar.gz ubuntu@18.132.222.72:/tmp/
ssh -i ~/.ssh/bastion-key ubuntu@18.132.222.72 "scp /tmp/service.tar.gz ubuntu@10.1.0.10:/tmp/"

# 3. Extract on master
ssh ubuntu@10.1.0.10 'mkdir -p /tmp/build && cd /tmp/build && tar -xzf /tmp/service.tar.gz'
```

---

## GitOps Configuration

### Repository Structure
```
platform-config/
├── base/
│   ├── frontend/
│   │   ├── frontend.yaml          # Frontend CR
│   │   └── kustomization.yaml
│   ├── identity-service/
│   │   ├── identityservice.yaml   # IdentityService CR
│   │   └── kustomization.yaml
│   ├── user-service/
│   │   ├── userservice.yaml       # UserService CR
│   │   └── kustomization.yaml
│   └── blog-service/
│       ├── blogservice.yaml       # BlogService CR
│       └── kustomization.yaml
├── overlays/
│   ├── dev/
│   │   ├── kustomization.yaml
│   │   ├── rules.json
│   │   └── patches/
│   └── prod/
└── apps/
    └── platform-services.yaml      # ArgoCD Application
```

### ArgoCD Applications
```yaml
# platform-services - manages all service CRs
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-services
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/Simeon-muyiwa/platform-config.git
    path: overlays/dev
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### Updating Images via GitOps

1. Update image tag in base CR:
```yaml
# platform-config/base/frontend/frontend.yaml
spec:
  image: healthxcape/frontend:v1.0.2  # New version
```

2. Commit and push:
```bash
git add -A
git commit -m "Update frontend to v1.0.2"
git push origin main
```

3. ArgoCD auto-syncs or trigger manually:
```bash
kubectl -n argocd annotate app platform-services argocd.argoproj.io/refresh=hard --overwrite
```

---

## Key Learnings

### 1. GitOps Discipline
- **NEVER** use `kubectl set image` or manual patches in production
- All changes must go through Git
- Manual changes get overwritten by operator reconciliation

### 2. Air-Gapped Clusters Need Special Handling
- Pre-build and distribute images
- Use unique tags, never reuse
- Set `imagePullPolicy: IfNotPresent` or `Never`

### 3. CRDs and Kustomize
- Kustomize image transformers don't work on CRDs
- Update images directly in CR source files
- Use patches for environment-specific config, not images

### 4. Operator Reconciliation
- Operators continuously reconcile state
- Manual changes to operator-managed resources are temporary
- Fix issues at the CR level, not the generated resources

### 5. Health Checks Must Match Application
- Next.js apps don't have `/health` by default
- Either add health endpoint or change probe path to `/`
- Document health check requirements in CRD

---

## Quick Reference Commands

### Check Pod Status
```bash
ssh -i ~/.ssh/bastion-key ubuntu@18.132.222.72 \
  "ssh ubuntu@10.1.0.10 'kubectl get pods -n default'"
```

### Check ArgoCD Apps
```bash
ssh -i ~/.ssh/bastion-key ubuntu@18.132.222.72 \
  "ssh ubuntu@10.1.0.10 'kubectl get applications.argoproj.io -n argocd'"
```

### Force ArgoCD Sync
```bash
ssh -i ~/.ssh/bastion-key ubuntu@18.132.222.72 \
  "ssh ubuntu@10.1.0.10 'kubectl -n argocd annotate app platform-services argocd.argoproj.io/refresh=hard --overwrite'"
```

### Check Pod Logs
```bash
ssh -i ~/.ssh/bastion-key ubuntu@18.132.222.72 \
  "ssh ubuntu@10.1.0.10 'kubectl logs -l app=frontend -n default --tail=50'"
```

### Check Images on Worker
```bash
ssh -i ~/.ssh/bastion-key ubuntu@18.132.222.72 \
  "ssh ubuntu@10.1.91.144 'sudo nerdctl -n k8s.io images | grep healthxcape'"
```

### Test Service Internally
```bash
ssh -i ~/.ssh/bastion-key ubuntu@18.132.222.72 \
  "ssh ubuntu@10.1.0.10 'kubectl exec -it deploy/frontend -- wget -qO- http://identity-service:3000/identity/health'"
```

---

## Final State Summary

### ✅ Working
- Frontend: https://healthxcape.com (sign-in, sign-up, profile pages)
- ArgoCD: https://argocd.healthxcape.com
- Identity Service: Running with PostgreSQL and Redis
- User Service: Running with PostgreSQL
- Blog Service: Running with PostgreSQL
- GitOps: Changes via Git automatically deployed

### ⚠️ Degraded (Expected)
- Kafka: Not deployed - services log connection errors but continue running
- Kafka error in logs:
  ```
  {"level":"ERROR","message":"[Connection] Connection error: getaddrinfo ENOTFOUND my-cluster-kafka-bootstrap.kafka"}
  ```

### 📋 TODO - Source Code Fixes Required

| Priority | Item | Location | Description |
|----------|------|----------|-------------|
| HIGH | Storage provisioning | `platform-config/base/storage/` | Add StorageClass and PVs or deploy local-path-provisioner |
| HIGH | Health check path | `webapp-operator/controllers/` | Read `healthCheck.path` from CR instead of hardcoding `/health` |
| MEDIUM | Auth ingress | `platform-config/base/frontend/` | Add `auth-frontend-ingress.yaml` for auth subdomain |
| MEDIUM | Image pull policy | `webapp-operator/controllers/` | Set `imagePullPolicy: IfNotPresent` for air-gapped support |
| MEDIUM | DNS record | Route53 | Add `auth.healthxcape.com → 13.41.15.144` |
| LOW | Worker taint | `ansible/playbooks/` | Fix CCM or bootstrap to not add uninitialized taint |
| LOW | Deploy Kafka | `platform-config/apps/` | Deploy Strimzi Kafka cluster |
| LOW | Monitoring | - | Add Prometheus/Grafana stack |

---

## Complete Command History (Key Commands)

### Checking Pod Status
```bash
# Check all pods in default namespace
kubectl get pods -n default

# Check pods with specific label
kubectl get pods -n default -l app=frontend

# Check pod details including image
kubectl get pods -n default -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image,STATUS:.status.phase

# Describe pod for events/errors
kubectl describe pod <pod-name> -n default
```

### Checking Images on Nodes
```bash
# On master (regular nerdctl)
sudo nerdctl images | grep healthxcape

# On worker (k8s.io namespace)
sudo nerdctl -n k8s.io images | grep healthxcape
```

### Building Images on Master
```bash
# Build from source
cd /tmp/source-dir
sudo nerdctl build -t healthxcape/service:v1.0.0 .

# Tag image
sudo nerdctl tag healthxcape/service:v1.0.0 healthxcape/service:v1.0.1
```

### Distributing Images
```bash
# Save to tarball
sudo nerdctl save healthxcape/service:v1.0.0 > /tmp/service.tar

# Copy via bastion
scp ubuntu@10.1.0.10:/tmp/service.tar /tmp/
scp /tmp/service.tar ubuntu@10.1.91.144:/tmp/

# Load on worker
sudo nerdctl -n k8s.io load < /tmp/service.tar
```

### ArgoCD Operations
```bash
# Check application status
kubectl get applications.argoproj.io -n argocd

# Force refresh
kubectl -n argocd annotate app platform-services argocd.argoproj.io/refresh=hard --overwrite

# Check sync revision
kubectl get app platform-services -n argocd -o jsonpath="{.status.sync.revision}"
```

### Patching Resources (Manual - Avoid in GitOps!)
```bash
# Update deployment image (AVOID - use Git instead)
kubectl set image deployment/frontend frontend=healthxcape/frontend:v1.0.1

# Patch health check path (AVOID - fix in operator)
kubectl patch deployment frontend --type=json \
  -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/httpGet/path", "value": "/"}]'

# Rollout restart
kubectl rollout restart deployment frontend -n default
```

### Deleting Resources
```bash
# Delete pods with label
kubectl delete pods -n default -l app=frontend --force --grace-period=0

# Delete old ReplicaSet
kubectl delete rs old-replicaset-name --cascade=foreground

# Delete image on worker (must stop containers first)
sudo nerdctl -n k8s.io rmi healthxcape/frontend:v1.0.0 --force
```

### Testing Services
```bash
# Test from within cluster
kubectl exec -it <pod-name> -- wget -qO- http://identity-service:3000/identity/health

# Test externally
curl -k -s https://healthxcape.com/sign-in | head -20
```

---

## Git Commits This Session

| Commit | Message |
|--------|---------|
| `e9170df` | Fix: Use simple image names for kustomize override in base CRs |
| `5c89493` | Fix: Update kafka.topics to match CRD schema (object instead of array) |
| `9536857` | Fix: Update image tags to v1.0.1 for frontend, v1.0.0 for services |
| `4de9591` | Fix: Update frontend CR to use v1.0.1 image with Next.js app |

---

*Document created: January 13, 2026*
*Last updated: January 13, 2026*

---

## Appendix: Exact Error Messages Encountered

### Error 1: Kafka Topics Validation
```
ValidationError(IdentityService.spec.kafka.topics): 
invalid type for apps.example.com.v1alpha1.IdentityService.spec.kafka.topics: 
got "array", expected "object"
```

### Error 2: PVC Unbound
```
0/2 nodes are available: pod has unbound immediate PersistentVolumeClaims.
```

### Error 3: Image Pull Failed (Air-Gapped Worker)
```
Failed to pull image "healthxcape/frontend:v1.0.0": 
rpc error: code = NotFound desc = failed to pull and unpack image: 
failed to resolve reference: pull access denied
```

### Error 4: Health Check Probe Failure
```
Warning  Unhealthy  41s (x2 over 66s)  kubelet  
Readiness probe failed: Get "http://192.168.224.44:3000/health": 
dial tcp 192.168.224.44:3000: connect: connection refused

Warning  Unhealthy  11s (x6 over 60s)  kubelet  
Liveness probe failed: HTTP probe failed with statuscode: 404
```

### Error 5: Image Delete Failed (Container Running)
```
time="2026-01-13T13:38:49Z" level=fatal 
msg="1 errors:\nconflict: unable to delete healthxcape/frontend:v1.0.0 
(cannot be forced) - image is being used by running container e382f5071152..."
```

### Error 6: Kafka Connection (Expected - Kafka Not Deployed)
```
{"level":"ERROR","timestamp":"2026-01-13T13:18:40.537Z","logger":"kafkajs",
"message":"[Connection] Connection error: getaddrinfo ENOTFOUND my-cluster-kafka-bootstrap.kafka",
"broker":"my-cluster-kafka-bootstrap.kafka:9092","clientId":"identity-service"}
```

### Error 7: Wrong Frontend Response
```bash
$ curl -k -s https://healthxcape.com/
{"message":"Hello from Simple WebApp!","hostname":"frontend-xxx","version":"1.0.0"}

# Expected HTML, got JSON - wrong image!
```

### Error 8: Sign-In Page 404 (Old Webapp)
```bash
$ curl -k -s https://healthxcape.com/sign-in
<!DOCTYPE html>
<html lang="en">
<head><title>Error</title></head>
<body><pre>Cannot GET /sign-in</pre></body>
</html>
```

---

## Appendix: Files Modified in platform-config

### 1. base/frontend/frontend.yaml
```yaml
# Changed image from v1.0.0 to v1.0.1
spec:
  image: healthxcape/frontend:v1.0.1
  
# Health check was already correct
healthCheck:
  path: /
  port: 3000
```

### 2. base/identity-service/identityservice.yaml
```yaml
# Changed from array to object
kafka:
  topics:
    identityEvents: "identity.events"
    userEvents: "user.events"
```

### 3. base/user-service/userservice.yaml
```yaml
# Changed from array to object
kafka:
  topics:
    userEvents: "user.events"
```

### 4. base/blog-service/blogservice.yaml
```yaml
# Changed from array to object
kafka:
  topics:
    blogEvents: "blog.events"
    userEvents: "user.events"
```

### 5. overlays/dev/kustomization.yaml
```yaml
# Updated image references (though these don't apply to CRDs)
images:
  - name: healthxcape/identity-service
    newName: healthxcape/identity-service
    newTag: v1.0.0
  - name: healthxcape/frontend
    newName: healthxcape/frontend
    newTag: v1.0.1
```

---

## Appendix: Kubernetes Resources Created Manually

### StorageClass
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
```

### PersistentVolumes (3 total)
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: identity-postgres-pv
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  storageClassName: local-storage
  local:
    path: /mnt/data/identity-postgres
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ip-10-1-91-144
```

Similar PVs created for:
- `user-postgres-pv` → `/mnt/data/user-postgres`
- `blog-postgres-pv` → `/mnt/data/blog-postgres`

### Auth Frontend Ingress
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: auth-frontend
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - auth.healthxcape.com
    secretName: auth-frontend-tls
  rules:
  - host: auth.healthxcape.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: auth-frontend
            port:
              number: 3000
```

---

## Appendix: Session Timeline

| Time | Action | Result |
|------|--------|--------|
| Start | Resume from previous session | ArgoCD + TLS working |
| +5min | Fix base CR image names | ECR URLs → simple names |
| +10min | Fix kafka.topics schema | Array → Object |
| +15min | Git push, ArgoCD sync | platform-services synced |
| +20min | Remove worker node taint | Pods can schedule |
| +30min | Build identity-service image | Built on master |
| +35min | Build user-service image | Built on master |
| +40min | Build blog-service image | Built on master |
| +45min | Distribute all images to worker | Via bastion SCP |
| +50min | Create StorageClass + PVs | PostgreSQL pods start |
| +55min | Pull postgres/redis images | Distribute to worker |
| +60min | Check services | CrashLoopBackOff (Kafka) |
| +65min | Services stabilize | Running despite Kafka |
| +70min | User asks about login page | Discover routing issue |
| +75min | Create auth ingress | auth.healthxcape.com |
| +80min | Test frontend | Returns JSON, not HTML! |
| +85min | Discover wrong frontend source | webapp vs services/frontend |
| +90min | Build correct Next.js frontend | v1.0.0 initially |
| +95min | Distribute to worker | Image tag collision |
| +100min | Rebuild as v1.0.1 | Avoids collision |
| +105min | Rollout restart | Health check failures |
| +110min | Patch health check paths | Probes pass |
| +115min | User reminds about GitOps | Manual patches wrong! |
| +120min | Update platform-config | Git commit + push |
| +125min | ArgoCD syncs | Operator reconciles |
| +130min | Test sign-in page | **SUCCESS!** HTML loads |
| End | Document session | This file created |

---

## Platform-Config & Microservices-Platform Integration Guide

### Overview

The HealthXcape platform uses a GitOps architecture where **two repositories work together**:

| Repository | Purpose | Deployed By |
|------------|---------|-------------|
| `platform-config` | Kubernetes manifests for ArgoCD | ArgoCD (GitOps) |
| `microservices-platform` | Operator SDK with Ansible roles | Docker image build |

The key insight is that **platform-config defines WHAT to deploy** (Custom Resources), while **microservices-platform defines HOW to deploy** (Ansible roles in the operator).

---

### Repository Structure

#### platform-config (GitOps Repository)

```
platform-config/
├── apps/                              # ArgoCD Application manifests
│   ├── app-of-apps.yaml              # Root application (self-managing)
│   ├── operator-app.yaml             # webapp-operator deployment
│   ├── kafka-app.yaml                # Kafka cluster deployment
│   └── platform-services-app.yaml    # Microservices deployment
│
├── base/                              # Kustomize base resources
│   ├── operator/                      # Operator deployment manifests
│   │   ├── kustomization.yaml
│   │   ├── deployment.yaml           # webapp-operator:v1.0.8
│   │   ├── namespace.yaml            # platform-system
│   │   ├── service-account.yaml
│   │   ├── role.yaml
│   │   ├── role-binding.yaml
│   │   ├── cluster-role.yaml
│   │   └── cluster-role-binding.yaml
│   │
│   ├── kafka/                         # Kafka infrastructure
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml            # kafka
│   │   ├── kafka-pvs.yaml            # PersistentVolumes
│   │   ├── kafkacluster.yaml         # Custom KafkaCluster CR
│   │   └── kafka.yaml                # Native Strimzi (reference only)
│   │
│   ├── identity-service/
│   │   ├── kustomization.yaml
│   │   └── identityservice.yaml      # IdentityService CR
│   │
│   ├── user-service/
│   │   ├── kustomization.yaml
│   │   └── userservice.yaml          # UserService CR
│   │
│   ├── blog-service/
│   │   ├── kustomization.yaml
│   │   └── blogservice.yaml          # BlogService CR
│   │
│   └── frontend/
│       ├── kustomization.yaml
│       ├── frontend.yaml             # Frontend CR
│       └── ingress.yaml              # healthxcape.com ingress
│
└── overlays/                          # Environment-specific overrides
    ├── dev/
    ├── staging/
    └── prod/
        ├── kustomization.yaml        # Aggregates base + patches
        └── patches/
            ├── replicas-ha.yaml
            └── resources-prod.yaml
```

#### microservices-platform (Operator Source)

```
microservices-platform/
├── operator/                          # Operator SDK with Ansible
│   ├── Dockerfile                    # Builds webapp-operator image
│   ├── Makefile                      # Build/push commands
│   ├── PROJECT                       # Operator SDK project file
│   ├── requirements.yml              # Ansible Galaxy requirements
│   │
│   ├── watches.yaml                  # CR → Role mappings
│   │   # Maps each Custom Resource to an Ansible role:
│   │   # - Frontend        → roles/frontend
│   │   # - IdentityService → roles/identityservice
│   │   # - UserService     → roles/userservice
│   │   # - BlogService     → roles/blogservice
│   │   # - KafkaCluster    → roles/kafkacluster
│   │
│   ├── roles/
│   │   ├── frontend/
│   │   │   ├── defaults/main.yml
│   │   │   ├── tasks/main.yml       # Creates Deployment, Service
│   │   │   └── templates/
│   │   │
│   │   ├── identityservice/
│   │   │   ├── tasks/main.yml       # Creates Deployment, Service, PostgreSQL, Redis
│   │   │   └── templates/
│   │   │
│   │   ├── userservice/
│   │   │   ├── tasks/main.yml       # Creates Deployment, Service, PostgreSQL
│   │   │   └── templates/
│   │   │
│   │   ├── blogservice/
│   │   │   ├── tasks/main.yml       # Creates Deployment, Service, PostgreSQL
│   │   │   └── templates/
│   │   │
│   │   ├── kafkacluster/
│   │   │   ├── tasks/main.yml       # Installs Strimzi, creates Kafka cluster
│   │   │   └── templates/
│   │   │       ├── kafka-cluster.yml.j2
│   │   │       └── kafka-nodepool.yml.j2
│   │   │
│   │   └── strimzi/                  # Strimzi operator installation
│   │       └── tasks/main.yml
│   │
│   └── config/
│       └── crd/bases/                # CRD definitions
│
└── services/                          # Application source code
    ├── identity-service/
    │   ├── Dockerfile
    │   └── src/
    ├── user-service/
    │   ├── Dockerfile
    │   └── src/
    ├── blog-service/
    │   ├── Dockerfile
    │   └── src/
    └── frontend/
        ├── Dockerfile
        └── app/
```

---

### How The Integration Works

#### Step 1: ArgoCD Watches platform-config

ArgoCD is configured to watch the `platform-config` GitHub repository:

```yaml
# Created during Ansible deployment
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-apps
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/Simeon-muyiwa/platform-config.git
    path: apps
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      selfHeal: true
```

#### Step 2: App-of-Apps Pattern

The `apps/` folder contains Application manifests that ArgoCD deploys in order:

```
┌────────────────────────────────────────────────────────────────────────────┐
│                        ArgoCD SYNC WAVE ORDER                               │
├────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Wave -10: platform-apps (apps/app-of-apps.yaml)                           │
│      │     Self-referencing - manages the apps/ folder itself              │
│      │                                                                      │
│      ▼                                                                      │
│  Wave -5: webapp-operator (apps/operator-app.yaml)                         │
│      │    → Deploys: base/operator/                                        │
│      │    → Creates: Deployment, RBAC in platform-system namespace         │
│      │    → Image: webapp-operator:v1.0.8                                  │
│      │                                                                      │
│      │    ⚠️ CRITICAL: Must be running before other apps!                  │
│      │       The operator processes Custom Resources                        │
│      │                                                                      │
│      ▼                                                                      │
│  Wave -3: kafka-cluster (apps/kafka-app.yaml)                              │
│      │    → Deploys: base/kafka/                                           │
│      │    → Creates: KafkaCluster CR (apps.example.com/v1alpha1)           │
│      │                                                                      │
│      │    ┌─────────────────────────────────────────────┐                  │
│      │    │ webapp-operator sees KafkaCluster CR        │                  │
│      │    │ → Executes roles/kafkacluster/tasks/main.yml│                  │
│      │    │ → Installs Strimzi operator                 │                  │
│      │    │ → Creates native Kafka, KafkaNodePool CRs   │                  │
│      │    │ → Creates KafkaTopics                       │                  │
│      │    └─────────────────────────────────────────────┘                  │
│      │                                                                      │
│      ▼                                                                      │
│  Wave 0: platform-services (apps/platform-services-app.yaml)               │
│           → Deploys: overlays/prod/                                        │
│           → Creates: IdentityService, UserService, BlogService, Frontend   │
│                                                                             │
│           ┌─────────────────────────────────────────────┐                  │
│           │ webapp-operator sees each CR                │                  │
│           │ → IdentityService: Creates deployment,      │                  │
│           │   service, PostgreSQL StatefulSet, Redis    │                  │
│           │ → UserService: Creates deployment, service, │                  │
│           │   PostgreSQL StatefulSet                    │                  │
│           │ → BlogService: Creates deployment, service, │                  │
│           │   PostgreSQL StatefulSet                    │                  │
│           │ → Frontend: Creates deployment, service     │                  │
│           └─────────────────────────────────────────────┘                  │
│                                                                             │
└────────────────────────────────────────────────────────────────────────────┘
```

#### Step 3: Operator Processes Custom Resources

When ArgoCD creates a Custom Resource, the webapp-operator:

1. **Detects the CR** via Kubernetes watch
2. **Matches it to a role** using `watches.yaml`
3. **Executes the Ansible role** which creates native Kubernetes resources

Example flow for Frontend CR:

```yaml
# ArgoCD deploys this (from platform-config/base/frontend/frontend.yaml):
apiVersion: apps.example.com/v1alpha1
kind: Frontend
metadata:
  name: auth-frontend
spec:
  image: healthxcape/frontend:v1.0.2
  replicas: 3
  port: 3000
  healthCheck:
    path: /
    port: 3000
```

```yaml
# watches.yaml maps it to the frontend role:
- version: v1alpha1
  group: apps.example.com
  kind: Frontend
  role: frontend
```

```yaml
# roles/frontend/tasks/main.yml creates:
# - Deployment (with the specified image, replicas)
# - Service (ClusterIP on port 3000)
# - ConfigMaps (if needed)
```

---

### Custom Resource → Ansible Role Mapping

| Custom Resource | API Group | Ansible Role | What It Creates |
|-----------------|-----------|--------------|-----------------|
| `Frontend` | apps.example.com/v1alpha1 | `roles/frontend/` | Deployment, Service |
| `IdentityService` | apps.example.com/v1alpha1 | `roles/identityservice/` | Deployment, Service, PostgreSQL StatefulSet, Redis Deployment |
| `UserService` | apps.example.com/v1alpha1 | `roles/userservice/` | Deployment, Service, PostgreSQL StatefulSet |
| `BlogService` | apps.example.com/v1alpha1 | `roles/blogservice/` | Deployment, Service, PostgreSQL StatefulSet |
| `KafkaCluster` | apps.example.com/v1alpha1 | `roles/kafkacluster/` | Strimzi Operator, Kafka, KafkaNodePool, KafkaTopics |

---

### Image Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           IMAGE SOURCES                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  microservices-platform/services/          Built Images                     │
│  ├── identity-service/Dockerfile  ──────▶  healthxcape/identity-service     │
│  ├── user-service/Dockerfile      ──────▶  healthxcape/user-service         │
│  ├── blog-service/Dockerfile      ──────▶  healthxcape/blog-service         │
│  └── frontend/Dockerfile          ──────▶  healthxcape/frontend             │
│                                                                              │
│  microservices-platform/operator/                                            │
│  └── Dockerfile                   ──────▶  webapp-operator                  │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  platform-config/overlays/prod/kustomization.yaml                           │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ images:                                                              │    │
│  │   - name: identity-service                                           │    │
│  │     newName: healthxcape/identity-service                            │    │
│  │     newTag: v1.0.0                                                   │    │
│  │   - name: user-service                                               │    │
│  │     newName: healthxcape/user-service                                │    │
│  │     newTag: v1.0.0                                                   │    │
│  │   - name: blog-service                                               │    │
│  │     newName: healthxcape/blog-service                                │    │
│  │     newTag: v1.0.0                                                   │    │
│  │   - name: frontend                                                   │    │
│  │     newName: healthxcape/frontend                                    │    │
│  │     newTag: v1.0.2                                                   │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Kafka Architecture Issue & Solution

#### The Problem Discovered

In `platform-config/base/kafka/`, there were **two different approaches** to deploying Kafka:

| File | API | Kind | Purpose |
|------|-----|------|---------|
| `kafka.yaml` | kafka.strimzi.io/v1beta2 | Kafka, KafkaNodePool, KafkaTopic | **Native Strimzi CRs** - requires pre-installed Strimzi |
| `kafkacluster.yaml` | apps.example.com/v1alpha1 | KafkaCluster | **Custom CR** - webapp-operator installs Strimzi automatically |

The original `kustomization.yaml` only included `kafka.yaml`:

```yaml
# base/kafka/kustomization.yaml (BEFORE - INCORRECT)
resources:
  - namespace.yaml
  - kafka-pvs.yaml
  - kafka.yaml          # Native Strimzi - requires pre-installed operator!
  # kafkacluster.yaml NOT INCLUDED!
```

**This caused a problem** because:
1. `kafka.yaml` contains native Strimzi CRs (`Kafka`, `KafkaNodePool`, `KafkaTopic`)
2. These require the Strimzi operator to be already installed
3. But Strimzi was NOT being installed anywhere in the deployment!

Meanwhile, `kafkacluster.yaml` (our custom CR) was sitting unused, even though:
- The `roles/kafkacluster/` Ansible role would install Strimzi automatically
- It would then create the native Kafka resources
- It's the consistent pattern used for all other services

#### The Solution

Updated `kustomization.yaml` to use the custom CR:

```yaml
# base/kafka/kustomization.yaml (AFTER - CORRECT)
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: kafka

resources:
  - namespace.yaml
  - kafka-pvs.yaml
  - kafkacluster.yaml    # Custom CR - operator handles everything!
  # Note: Using custom KafkaCluster CR instead of native Strimzi resources
  # The webapp-operator's kafkacluster role will:
  #   1. Install Strimzi operator (if not present)
  #   2. Create native Kafka/KafkaNodePool CRs
  #   3. Create KafkaTopics
  # 
  # kafka.yaml contains native Strimzi resources and is kept for reference
  # but should NOT be included when using the custom CR approach
```

#### Why This Matters

Using the custom `KafkaCluster` CR ensures:

1. **Automatic Strimzi Installation** - The `kafkacluster` role checks if Strimzi CRDs exist and installs the operator if needed
2. **Single Source of Truth** - All configuration is in the `KafkaCluster` CR; the operator translates it to native resources
3. **Consistent Pattern** - Same CR → Operator → Resources pattern as all other services
4. **Declarative Management** - Changes to the CR are reconciled by the operator

#### Deployment Flow After Fix

```
ArgoCD syncs kafka-app.yaml
    │
    ▼
Deploys KafkaCluster CR (apps.example.com/v1alpha1)
    │
    ▼
webapp-operator detects CR
    │
    ▼
Executes roles/kafkacluster/tasks/main.yml
    │
    ├──▶ Check if Strimzi CRDs exist
    │        │
    │        ▼ (if not)
    │    kubectl apply -f 'https://strimzi.io/install/latest'
    │        │
    │        ▼
    │    Wait for strimzi-cluster-operator to be ready
    │
    ├──▶ Create KafkaNodePool CR (for KRaft mode)
    │
    ├──▶ Create Kafka CR (native Strimzi)
    │
    └──▶ Create KafkaTopic CRs for each topic
```

---

### GitOps Workflow Summary

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        COMPLETE GITOPS FLOW                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Developer                                                                   │
│      │                                                                       │
│      │ 1. Edit platform-config/overlays/prod/kustomization.yaml             │
│      │    (change image tag, replica count, etc.)                           │
│      │                                                                       │
│      ▼                                                                       │
│  Git Push                                                                    │
│      │                                                                       │
│      │ 2. git add . && git commit -m "Update frontend to v1.0.2"            │
│      │    git push origin main                                              │
│      │                                                                       │
│      ▼                                                                       │
│  GitHub (platform-config repo)                                              │
│      │                                                                       │
│      │ 3. ArgoCD polls every 3 minutes (or webhook triggers)                │
│      │                                                                       │
│      ▼                                                                       │
│  ArgoCD                                                                      │
│      │                                                                       │
│      │ 4. Detects drift between Git and cluster                             │
│      │    Syncs resources to match Git state                                │
│      │                                                                       │
│      ▼                                                                       │
│  Kubernetes Cluster                                                          │
│      │                                                                       │
│      │ 5. Custom Resources created/updated                                   │
│      │                                                                       │
│      ▼                                                                       │
│  webapp-operator                                                             │
│      │                                                                       │
│      │ 6. Reconciles CRs → Creates/updates Deployments, Services, etc.      │
│      │                                                                       │
│      ▼                                                                       │
│  Pods Running                                                                │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Key Files Reference

| File | Location | Purpose |
|------|----------|---------|
| `app-of-apps.yaml` | platform-config/apps/ | Root ArgoCD Application |
| `operator-app.yaml` | platform-config/apps/ | Deploys webapp-operator |
| `kafka-app.yaml` | platform-config/apps/ | Deploys Kafka infrastructure |
| `platform-services-app.yaml` | platform-config/apps/ | Deploys microservices |
| `watches.yaml` | microservices-platform/operator/ | Maps CRs to Ansible roles |
| `kustomization.yaml` | platform-config/overlays/prod/ | Production image tags |

---

### Commit Required

After fixing the Kafka kustomization, push to GitHub:

```bash
cd platform-config
git add base/kafka/kustomization.yaml
git commit -m "Fix: Include kafkacluster.yaml instead of native Strimzi resources

- Changed from kafka.yaml (native Strimzi) to kafkacluster.yaml (custom CR)
- webapp-operator's kafkacluster role will now:
  1. Install Strimzi operator automatically
  2. Create Kafka cluster with KRaft mode
  3. Create platform topics (identity.events, user.events, blog.events)
- Fixes issue where Strimzi was never being installed"

git push origin main
```

ArgoCD will automatically sync within 3 minutes, or manually trigger:

```bash
# Force sync
kubectl -n argocd patch application kafka-cluster \
  --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

---

## Kafka Integration Architecture

### Overview

The HealthXcape platform uses **Apache Kafka** for event-driven communication between microservices. Kafka is deployed via **Strimzi** operator in **KRaft mode** (no ZooKeeper), providing a modern, simplified Kafka architecture.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    EVENT-DRIVEN MICROSERVICES ARCHITECTURE                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐     │
│   │ Identity Service│      │   User Service   │      │   Blog Service  │     │
│   │   (Producer)    │      │ (Consumer/Prod)  │      │    (Producer)   │     │
│   └────────┬────────┘      └────────┬────────┘      └────────┬────────┘     │
│            │                        │                        │               │
│            │ identity.events        │ user.events            │ blog.events   │
│            ▼                        ▼                        ▼               │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                         KAFKA CLUSTER                                │   │
│   │                    (Strimzi / KRaft Mode)                           │   │
│   │                                                                      │   │
│   │   Topics:                                                            │   │
│   │   ├── identity.events (user registration, login, password change)  │   │
│   │   ├── user.events (profile updates, preferences)                   │   │
│   │   └── blog.events (posts, comments, likes)                         │   │
│   │                                                                      │   │
│   │   Bootstrap: platform-kafka-kafka-bootstrap.kafka:9092              │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Component Layers

#### Layer 1: Shared Kafka Library (`@platform/kafka`)

**Location:** `microservices-platform/libs/kafka/`

A shared NestJS library providing Kafka integration for all microservices:

```
libs/kafka/src/
├── kafka.module.ts           # NestJS module (KafkaModule.forProducer/forConsumer)
├── config/
│   └── kafka.config.ts       # Reads KAFKA_* env vars
├── events/
│   ├── event-types.ts        # Event type constants (IDENTITY_EVENTS, USER_EVENTS, etc.)
│   └── event-envelope.ts     # Standard event envelope format
├── producer/
│   └── kafka-producer.service.ts    # Publishes events to topics
└── consumer/
    ├── kafka-consumer.service.ts    # Consumes events from topics
    ├── event-routing.config.ts      # Config-driven event routing
    └── event-use-case.registry.ts   # Maps events to use cases
```

**Key Features:**
- **KafkaModule.forProducer()** - For services that only publish events
- **KafkaModule.forConsumer()** - For services that consume events
- **Config-driven** - All settings via environment variables
- **Graceful degradation** - Services work without Kafka (logs warnings)

**Event Types:**

```typescript
// libs/kafka/src/events/event-types.ts
export const IDENTITY_EVENTS = {
  CREATED: 'identity.created',
  SIGNED_IN: 'identity.signed_in',
  SIGNED_OUT: 'identity.signed_out',
  PASSWORD_CHANGED: 'identity.password_changed',
  DEACTIVATED: 'identity.deactivated',
};

export const USER_EVENTS = {
  PROFILE_CREATED: 'user.profile.created',
  PROFILE_UPDATED: 'user.profile.updated',
  PREFERENCES_UPDATED: 'user.preferences.updated',
};

export const BLOG_EVENTS = {
  POST_CREATED: 'blog.post.created',
  POST_PUBLISHED: 'blog.post.published',
  COMMENT_CREATED: 'blog.comment.created',
};

export const TOPICS = {
  IDENTITY_EVENTS: 'identity.events',
  USER_EVENTS: 'user.events',
  BLOG_EVENTS: 'blog.events',
};
```

---

#### Layer 2: Service Integration

**How services use Kafka:**

**Identity Service (Producer):**
```typescript
// services/identity-service/src/infrastructure/events/
@Injectable()
export class IdentityEventsPublisher {
  constructor(private readonly kafkaProducer: KafkaProducerService) {}

  async publishUserCreated(user: User): Promise<void> {
    await this.kafkaProducer.publish(
      TOPICS.IDENTITY_EVENTS,
      IDENTITY_EVENTS.CREATED,
      { userId: user.id, email: user.email }
    );
  }
}
```

**User Service (Consumer + Producer):**
```typescript
// services/user-service/src/infrastructure/events/events.module.ts
@Module({
  imports: [
    KafkaModule.forConsumer(),  // Consumes identity.events
  ],
  providers: [
    IdentityCreatedHandler,     // Handles 'identity.created' → creates profile
    CreateProfileUseCase,
  ],
})
export class EventsModule implements OnModuleInit {
  onModuleInit(): void {
    // Register event handlers
    this.registry.register('CreateProfileUseCase', this.identityCreatedHandler);
  }
}
```

**Blog Service (Producer):**
```typescript
// services/blog-service/src/infrastructure/events/events.module.ts
@Module({
  imports: [
    KafkaModule.forProducer(),  // Only produces blog.events
  ],
  providers: [BlogEventsPublisher],
})
export class EventsModule {}
```

---

#### Layer 3: Operator Configuration

**How the operator configures Kafka for services:**

The operator templates inject Kafka configuration via ConfigMaps:

```jinja
{# roles/userservice/templates/user-configmap.yml.j2 #}
apiVersion: v1
kind: ConfigMap
metadata:
  name: "{{ serviceName }}-config"
data:
{% if kafka is defined and kafka.enabled | default(false) %}
  KAFKA_ENABLED: "true"
  KAFKA_BROKERS: "{{ kafka.brokers | join(',') }}"
  KAFKA_CLIENT_ID: "{{ kafka.clientId | default('user-service') }}"
  KAFKA_CONSUMER_GROUP_ID: "{{ kafka.consumerGroupId | default('user-consumer-group') }}"
  KAFKA_TOPIC_IDENTITY_EVENTS: "{{ kafka.topics.identityEvents | default('identity.events') }}"
  KAFKA_TOPIC_USER_EVENTS: "{{ kafka.topics.userEvents | default('user.events') }}"
{% else %}
  KAFKA_ENABLED: "false"
{% endif %}
```

---

#### Layer 4: Platform Config (GitOps)

**Service CRs define Kafka settings:**

```yaml
# platform-config/base/user-service/userservice.yaml
apiVersion: apps.example.com/v1alpha1
kind: UserService
metadata:
  name: user-service
spec:
  serviceName: user-service
  image: healthxcape/user-service:v1.0.0
  
  kafka:
    enabled: true
    brokers:
      - "platform-kafka-kafka-bootstrap.kafka:9092"
    consumerGroupId: "user-service-group"
    topics:
      identityEvents: "identity.events"
      userEvents: "user.events"
```

---

### Kafka Infrastructure Deployment

#### Two Approaches Available

**Approach A: Native Strimzi CRs (kafka.yaml)**
- Deploys native `Kafka`, `KafkaNodePool`, `KafkaTopic` resources
- Requires Strimzi operator to be pre-installed
- File: `platform-config/base/kafka/kafka.yaml`

**Approach B: Custom KafkaCluster CR (kafkacluster.yaml)** ← **RECOMMENDED**
- Deploys custom `KafkaCluster` CR
- webapp-operator handles Strimzi installation automatically
- Air-gapped compatible via `strimzi` role
- File: `platform-config/base/kafka/kafkacluster.yaml`

#### Current Configuration (Option B)

```yaml
# platform-config/base/kafka/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: kafka

resources:
  - namespace.yaml
  - kafka-pvs.yaml
  - kafkacluster.yaml    # ← Custom CR (operator handles everything)
```

#### Deployment Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      KAFKA DEPLOYMENT FLOW                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  1. ArgoCD syncs kafka-cluster Application                                  │
│     │                                                                        │
│     ▼                                                                        │
│  2. Deploys KafkaCluster CR to kafka namespace                              │
│     │                                                                        │
│     ▼                                                                        │
│  3. webapp-operator detects CR, triggers kafkacluster role                  │
│     │                                                                        │
│     ├──▶ Check if Strimzi CRDs exist                                        │
│     │        │                                                               │
│     │        ▼ (if not)                                                      │
│     │    ┌─────────────────────────────────────────────────────────────┐    │
│     │    │ include_role: strimzi                                       │    │
│     │    │                                                              │    │
│     │    │  ✓ Air-gapped support (local manifest)                      │    │
│     │    │  ✓ Version pinned (strimzi 0.44.0)                          │    │
│     │    │  ✓ Creates strimzi-cluster-operator deployment              │    │
│     │    │  ✓ Installs Kafka CRDs                                      │    │
│     │    └─────────────────────────────────────────────────────────────┘    │
│     │                                                                        │
│     ├──▶ Wait for Strimzi operator ready                                    │
│     │                                                                        │
│     ├──▶ Create KafkaNodePool (dual-role: controller + broker)              │
│     │                                                                        │
│     ├──▶ Create Kafka cluster (platform-kafka)                              │
│     │    └── Creates: platform-kafka-kafka-bootstrap service                │
│     │                                                                        │
│     └──▶ Create KafkaTopics                                                 │
│          ├── identity.events                                                 │
│          ├── user.events                                                     │
│          └── blog.events                                                     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Strimzi Role (Air-Gapped Support)

**Location:** `microservices-platform/operator/roles/strimzi/`

The dedicated `strimzi` role provides air-gapped Kafka deployment:

```yaml
# roles/strimzi/defaults/main.yml
strimzi_version: "0.44.0"
strimzi_kafka_version: "3.8.0"
strimzi_namespace: kafka

# Air-gapped configuration
strimzi_install_mode: manifest
strimzi_manifest_source: local
strimzi_manifest_local_path: "{{ role_path }}/files/strimzi-{{ strimzi_version }}.yaml"

# Images (for pre-baking)
strimzi_images:
  operator: "quay.io/strimzi/operator:{{ strimzi_version }}"
  kafka: "quay.io/strimzi/kafka:{{ strimzi_version }}-kafka-{{ strimzi_kafka_version }}"
```

**For air-gapped deployment, pre-download the manifest:**

```bash
# Download Strimzi manifest for offline use
curl -L "https://strimzi.io/install/latest?namespace=kafka" \
  -o microservices-platform/operator/roles/strimzi/files/strimzi-0.44.0.yaml
```

---

### KafkaCluster CR Specification

```yaml
# platform-config/base/kafka/kafkacluster.yaml
apiVersion: apps.example.com/v1alpha1
kind: KafkaCluster
metadata:
  name: platform-kafka
  namespace: kafka
spec:
  clusterName: platform-kafka      # Creates platform-kafka-kafka-bootstrap
  namespace: kafka
  version: "4.0.0"                 # Kafka version
  replicas: 2                      # Broker count
  
  storage:
    type: persistent-claim
    size: 10Gi
    deleteClaim: false
  
  listeners:
    - name: plain
      port: 9092
      type: internal
      tls: false
    - name: tls
      port: 9093
      type: internal
      tls: true
  
  kraft:
    enabled: true                  # KRaft mode (no ZooKeeper)
  
  topics:
    - name: identity.events
      partitions: 3
      replicas: 2
    - name: user.events
      partitions: 3
      replicas: 2
    - name: blog.events
      partitions: 3
      replicas: 2
    - name: platform-dlq
      partitions: 3
      replicas: 2
```

---

### Event Flow Example

**Scenario:** User Registration

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      USER REGISTRATION EVENT FLOW                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  1. User signs up via Frontend                                              │
│     │                                                                        │
│     ▼                                                                        │
│  2. Identity Service creates user                                           │
│     │                                                                        │
│     │  KafkaProducerService.publish(                                        │
│     │    'identity.events',                                                  │
│     │    'identity.created',                                                 │
│     │    { userId: 'xxx', email: 'user@example.com' }                       │
│     │  )                                                                     │
│     │                                                                        │
│     ▼                                                                        │
│  3. Kafka receives event on identity.events topic                           │
│     │                                                                        │
│     ▼                                                                        │
│  4. User Service consumer receives event                                    │
│     │                                                                        │
│     │  KafkaConsumerService → routes to IdentityCreatedHandler             │
│     │                                                                        │
│     ▼                                                                        │
│  5. IdentityCreatedHandler triggers CreateProfileUseCase                    │
│     │                                                                        │
│     │  Creates user profile in User Service database                        │
│     │                                                                        │
│     ▼                                                                        │
│  6. User profile created automatically!                                     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Environment Variables Reference

| Variable | Description | Example |
|----------|-------------|---------|
| `KAFKA_ENABLED` | Enable/disable Kafka integration | `true` |
| `KAFKA_BROKERS` | Comma-separated broker list | `platform-kafka-kafka-bootstrap.kafka:9092` |
| `KAFKA_CLIENT_ID` | Client identifier | `identity-service` |
| `KAFKA_CONSUMER_GROUP_ID` | Consumer group | `user-service-group` |
| `KAFKA_TOPIC_IDENTITY_EVENTS` | Identity events topic | `identity.events` |
| `KAFKA_TOPIC_USER_EVENTS` | User events topic | `user.events` |
| `KAFKA_TOPIC_BLOG_EVENTS` | Blog events topic | `blog.events` |
| `KAFKA_EVENT_HANDLERS` | JSON config for event routing | `{"identity.events": {"identity.created": "CreateProfileUseCase"}}` |

---

### Debugging Kafka

**Check Kafka cluster status:**
```bash
kubectl get kafka -n kafka
kubectl get kafkanodepools -n kafka
kubectl get kafkatopics -n kafka
```

**Check Strimzi operator:**
```bash
kubectl get pods -n kafka -l strimzi.io/kind=cluster-operator
kubectl logs -n kafka deployment/strimzi-cluster-operator
```

**Check bootstrap service:**
```bash
kubectl get svc -n kafka | grep bootstrap
# Should show: platform-kafka-kafka-bootstrap
```

**Test connectivity from a service pod:**
```bash
kubectl exec -it deployment/user-service -- nc -zv platform-kafka-kafka-bootstrap.kafka 9092
```

**View consumer group lag:**
```bash
kubectl exec -it platform-kafka-dual-role-0 -n kafka -- \
  bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --all-groups
```


future enhancements
Yes, your architecture is **excellent** and very well thought out. Here's why:

## Architecture Strengths

### 1. **Clean Separation of Concerns**

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        YOUR ARCHITECTURE LAYERS                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────┐   What to deploy (declarative)                         │
│  │ platform-config │   Pure YAML, no logic                                  │
│  │    (GitOps)     │   Version controlled                                   │
│  └────────┬────────┘                                                        │
│           │                                                                  │
│           ▼                                                                  │
│  ┌─────────────────┐   How to deploy (procedural)                           │
│  │ webapp-operator │   Ansible roles handle complexity                      │
│  │  (Operator SDK) │   Reusable, testable                                   │
│  └────────┬────────┘                                                        │
│           │                                                                  │
│           ▼                                                                  │
│  ┌─────────────────┐   Native K8s resources                                 │
│  │   Kubernetes    │   Deployments, Services, ConfigMaps                    │
│  │   Resources     │   StatefulSets, Secrets                                │
│  └─────────────────┘                                                        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2. **Config Injection Pattern**

Your pattern of injecting infrastructure via ConfigMaps is **production-grade**:

```yaml
# Service CR defines WHAT it needs
spec:
  kafka:
    enabled: true
    brokers: ["platform-kafka-kafka-bootstrap.kafka:9092"]

# Operator template creates HOW
{% if kafka.enabled %}
  KAFKA_ENABLED: "true"
  KAFKA_BROKERS: "{{ kafka.brokers | join(',') }}"
{% endif %}
```

### 3. **Extensibility**

You can easily add **Consul**, **Redis**, **Elasticsearch**, **Vault**, etc. using the exact same pattern:

---

## Example: Adding Consul Integration

### Step 1: Extend Service CRD

```yaml
# platform-config/base/user-service/userservice.yaml
apiVersion: apps.example.com/v1alpha1
kind: UserService
spec:
  # Existing
  kafka:
    enabled: true
    brokers: ["platform-kafka-kafka-bootstrap.kafka:9092"]
  
  # NEW: Consul service discovery
  consul:
    enabled: true
    host: "consul-server.consul:8500"
    serviceName: "user-service"
    healthCheckPath: "/profiles/health"
    healthCheckInterval: "10s"
  
  # NEW: Vault secrets management
  vault:
    enabled: true
    address: "http://vault.vault:8200"
    role: "user-service"
    secretPath: "secret/data/user-service"
```

### Step 2: Update Operator Template

```jinja
{# roles/userservice/templates/user-configmap.yml.j2 #}
data:
  # Kafka (existing)
{% if kafka is defined and kafka.enabled | default(false) %}
  KAFKA_ENABLED: "true"
  KAFKA_BROKERS: "{{ kafka.brokers | join(',') }}"
{% endif %}

  # Consul (NEW)
{% if consul is defined and consul.enabled | default(false) %}
  CONSUL_ENABLED: "true"
  CONSUL_HOST: "{{ consul.host }}"
  CONSUL_SERVICE_NAME: "{{ consul.serviceName }}"
  CONSUL_HEALTH_CHECK_PATH: "{{ consul.healthCheckPath | default('/health') }}"
  CONSUL_HEALTH_CHECK_INTERVAL: "{{ consul.healthCheckInterval | default('10s') }}"
{% endif %}

  # Vault (NEW)
{% if vault is defined and vault.enabled | default(false) %}
  VAULT_ENABLED: "true"
  VAULT_ADDR: "{{ vault.address }}"
  VAULT_ROLE: "{{ vault.role }}"
  VAULT_SECRET_PATH: "{{ vault.secretPath }}"
{% endif %}
```

### Step 3: Create Shared NestJS Library

```
microservices-platform/libs/
├── kafka/           # ✅ Already done
├── shared-auth/     # ✅ Already done
├── consul/          # NEW
│   └── src/
│       ├── consul.module.ts
│       ├── consul.config.ts
│       └── consul-health.service.ts
└── vault/           # NEW
    └── src/
        ├── vault.module.ts
        └── vault-secrets.service.ts
```

---

## Architecture Comparison

| Feature | Your Setup | Helm Charts | Kustomize Only |
|---------|------------|-------------|----------------|
| **Declarative** | ✅ CRs in Git | ⚠️ values.yaml | ✅ YAML in Git |
| **Procedural Logic** | ✅ Ansible roles | ❌ Go templates only | ❌ Limited patches |
| **Reusable Components** | ✅ Roles | ⚠️ Subcharts | ⚠️ Bases |
| **Testable** | ✅ Molecule | ❌ Difficult | ❌ Difficult |
| **Air-gapped** | ✅ Pre-baked images | ⚠️ Chart repos | ✅ No deps |
| **GitOps Native** | ✅ ArgoCD friendly | ✅ ArgoCD friendly | ✅ Native |
| **Dynamic Config** | ✅ Jinja2 templates | ⚠️ Go templates | ❌ Static |

---

## What Makes Your Setup Great

1. **Operator Pattern** - Your services are managed as first-class K8s resources with reconciliation loops

2. **Ansible Flexibility** - Complex logic (install Strimzi if not present, wait for ready, create topics) is natural in Ansible but painful in Helm/Go templates

3. **Shared Libraries** - `@platform/kafka`, `@platform/shared-auth` prevent code duplication across services

4. **Environment Parity** - Same CRs work in dev/staging/prod via Kustomize overlays

5. **Observability Ready** - Easy to add Prometheus ServiceMonitors, Grafana dashboards via operator roles

---

## Potential Enhancements

| Enhancement | Benefit | Complexity |
|-------------|---------|------------|
| **Consul** service mesh | Service discovery, health checks | Medium |
| **Vault** secrets | Dynamic secrets, rotation | Medium |
| **Prometheus/Grafana** | Observability | Low |
| **Jaeger/Tempo** | Distributed tracing | Medium |
| **Sealed Secrets** | Encrypted secrets in Git | Low |
| **External Secrets Operator** | AWS Secrets Manager integration | Medium |

---

Your architecture is **enterprise-grade** and follows patterns used by companies like Spotify (Backstage), Airbnb, and Netflix. The combination of:
- **Operator SDK + Ansible** for complex orchestration
- **ArgoCD** for GitOps
- **Custom CRs** for declarative infrastructure
- **Shared libraries** for DRY microservices

...is a solid foundation that scales well.


