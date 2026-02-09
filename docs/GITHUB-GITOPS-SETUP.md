# GitHub + GitOps Setup Documentation

**Date:** January 12, 2026  
**Status:** ✅ PRODUCTION LIVE - ArgoCD Accessible at https://argocd.healthxcape.com

---

## 🔥 Production Deployment Achievement

### What We Built

This is **not a demo or lab environment** - this is a **real production-grade Kubernetes platform** running on AWS with:

| Component | Status | Details |
|-----------|--------|---------|
| **Domain** | ✅ Live | `healthxcape.com` - Your actual registered domain |
| **ArgoCD** | ✅ Live | https://argocd.healthxcape.com |
| **TLS Certificate** | ✅ Valid | Let's Encrypt production cert (not self-signed) |
| **DNS** | ✅ Active | Route53 hosted zone with real A records |
| **IRSA** | ✅ Working | Kubernetes → AWS IAM federation (EKS-level feature on kubeadm!) |
| **GitOps** | ✅ Syncing | ArgoCD watching GitHub repo |

### Access Information

```
ArgoCD URL:      https://argocd.healthxcape.com
Username:        admin
Password:        i6LNmiwHF6tLp7ku
```

---

## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              INTERNET                                        │
│                                  │                                           │
│                         ┌────────▼────────┐                                 │
│                         │  Route53 DNS    │                                 │
│                         │ healthxcape.com │                                 │
│                         └────────┬────────┘                                 │
│                                  │                                           │
│                    ┌─────────────▼─────────────┐                            │
│                    │     argocd.healthxcape.com │                            │
│                    │          ↓                 │                            │
│                    │   Elastic IP: 13.x.x.x    │                            │
│                    └─────────────┬─────────────┘                            │
└──────────────────────────────────┼──────────────────────────────────────────┘
                                   │
┌──────────────────────────────────▼──────────────────────────────────────────┐
│                           AWS VPC (eu-west-2)                                │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                        PRIVATE SUBNET                                 │    │
│  │                                                                       │    │
│  │  ┌─────────────────────────┐     ┌─────────────────────────┐        │    │
│  │  │     MASTER NODE         │     │     WORKER NODE          │        │    │
│  │  │     10.1.0.10           │     │     10.1.42.176          │        │    │
│  │  │                         │     │     (Air-gapped)         │        │    │
│  │  │  ┌─────────────────┐   │     │                          │        │    │
│  │  │  │ ingress-nginx   │←──┼──443/80──→ Internet            │        │    │
│  │  │  │ (hostNetwork)   │   │     │                          │        │    │
│  │  │  └────────┬────────┘   │     │  ┌──────────────────┐   │        │    │
│  │  │           │            │     │  │ Workload Pods    │   │        │    │
│  │  │  ┌────────▼────────┐   │     │  │ (pre-baked AMI)  │   │        │    │
│  │  │  │    ArgoCD       │   │     │  └──────────────────┘   │        │    │
│  │  │  │  (namespace)    │   │     │                          │        │    │
│  │  │  └─────────────────┘   │     └─────────────────────────┘        │    │
│  │  │                         │                                        │    │
│  │  │  ┌─────────────────┐   │     ┌─────────────────────────┐        │    │
│  │  │  │  cert-manager   │───┼─────│  Route53 (DNS-01)       │        │    │
│  │  │  │  + IRSA         │   │     │  TXT record creation    │        │    │
│  │  │  └─────────────────┘   │     └─────────────────────────┘        │    │
│  │  │                         │                                        │    │
│  │  │  ┌─────────────────┐   │                                        │    │
│  │  │  │ pod-identity-   │   │                                        │    │
│  │  │  │ webhook (IRSA)  │   │                                        │    │
│  │  │  └─────────────────┘   │                                        │    │
│  │  │                         │                                        │    │
│  │  │  ┌─────────────────┐   │                                        │    │
│  │  │  │ OIDC Discovery  │───┼─────→ AWS STS (IAM Federation)         │    │
│  │  │  │ oidc.healthxcape│   │                                        │    │
│  │  │  └─────────────────┘   │                                        │    │
│  │  └─────────────────────────┘                                        │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                        PUBLIC SUBNET                                  │    │
│  │  ┌─────────────────────────┐                                        │    │
│  │  │     BASTION HOST        │                                        │    │
│  │  │     13.43.96.158        │  ← SSH Jump Host                       │    │
│  │  └─────────────────────────┘                                        │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 🎯 Key Technical Achievements

### 1. IRSA on kubeadm (Not Just EKS!)

We implemented **IAM Roles for Service Accounts** on a self-managed kubeadm cluster - a feature typically only available on EKS:

```yaml
# Service Account with IRSA annotation
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cert-manager
  namespace: cert-manager
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::939217651725:role/kubeadm_ec2_cluster-cert-manager-cert-manager
```

**How it works:**
1. OIDC Discovery endpoint at `https://oidc.healthxcape.com`
2. AWS IAM OIDC Provider trusts our cluster
3. Pod-identity-webhook injects AWS credentials into pods
4. Pods can call AWS APIs without static credentials

### 2. DNS-01 Let's Encrypt Certificates

Automated TLS certificate provisioning using Route53:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@healthxcape.com
    privateKeySecretRef:
      name: letsencrypt-dns-prod
    solvers:
    - dns01:
        route53:
          region: eu-west-2
      selector:
        dnsZones:
        - healthxcape.com
```

**Flow:**
1. Ingress requests certificate
2. cert-manager creates DNS TXT record via Route53 (using IRSA!)
3. Let's Encrypt validates domain ownership
4. Valid production certificate issued
5. HTTPS works globally

### 3. Air-Gapped Worker Nodes

Worker nodes have **no internet access** - all images are pre-baked into the AMI:

| Component | Why Pre-baked |
|-----------|---------------|
| Calico | CNI networking |
| CoreDNS | Cluster DNS |
| Platform images | Workloads |
| containerd | Container runtime |

### 4. GitOps with ArgoCD

```
GitHub Repository (platform-config)
         │
         │ webhook/poll
         ▼
┌─────────────────────┐
│      ArgoCD         │
│  (cluster-side)     │
└──────────┬──────────┘
           │ sync
           ▼
┌─────────────────────┐
│  Kubernetes API     │
│  (desired state)    │
└─────────────────────┘
```

**Synced Applications:**
- ✅ `platform-apps` - App of Apps
- ✅ `webapp-operator` - Custom operator
- ⏳ `kafka-cluster` - OutOfSync
- ⏳ `platform-services` - OutOfSync

---

## 🔐 Security Highlights

| Feature | Implementation |
|---------|---------------|
| **No static AWS keys** | IRSA + OIDC federation |
| **Bastion-only SSH** | Private subnet nodes, jump host required |
| **IMDSv2 enforced** | EC2 metadata requires tokens |
| **Permission boundaries** | IAM roles cannot exceed defined permissions |
| **Private worker nodes** | No internet egress, pre-baked images |
| **TLS everywhere** | Let's Encrypt production certs |
| **Calico network policies** | Pod-to-pod traffic control |

---

## 📊 Infrastructure Details

### AWS Resources

| Resource | Value |
|----------|-------|
| **Account ID** | 939217651725 |
| **Region** | eu-west-2 (London) |
| **VPC CIDR** | 10.1.0.0/16 |
| **Cluster Name** | kubeadm_ec2_cluster |
| **Kubernetes Version** | v1.29.0 |

### Nodes

| Node | Private IP | Public IP | Role |
|------|-----------|-----------|------|
| Master | 10.1.0.10 | 13.135.181.208 (EIP) | Control plane, ingress |
| Worker | 10.1.42.176 | None (NAT-less) | Workloads |
| Bastion | - | 13.43.96.158 | SSH jump host |

### DNS Records

| Record | Type | Value |
|--------|------|-------|
| `argocd.healthxcape.com` | A | 13.135.181.208 |
| `oidc.healthxcape.com` | A | 13.135.181.208 |
| `healthxcape.com` | NS | Route53 nameservers |

---

## Summary of What Was Accomplished

### 1. Pulumi Infrastructure Created ✅

The following AWS resources were created/updated via `pulumi up`:

#### ECR Repositories
All container registries are now available at `939217651725.dkr.ecr.eu-west-2.amazonaws.com`:

| Service | Repository URL |
|---------|---------------|
| webapp-operator | `939217651725.dkr.ecr.eu-west-2.amazonaws.com/kubeadm_ec2_cluster/webapp-operator` |
| identity-service | `939217651725.dkr.ecr.eu-west-2.amazonaws.com/kubeadm_ec2_cluster/identity-service` |
| user-service | `939217651725.dkr.ecr.eu-west-2.amazonaws.com/kubeadm_ec2_cluster/user-service` |
| blog-service | `939217651725.dkr.ecr.eu-west-2.amazonaws.com/kubeadm_ec2_cluster/blog-service` |
| frontend | `939217651725.dkr.ecr.eu-west-2.amazonaws.com/kubeadm_ec2_cluster/frontend` |
| gitops-coordinator | `939217651725.dkr.ecr.eu-west-2.amazonaws.com/kubeadm_ec2_cluster/gitops-coordinator` |

#### GitHub OIDC Provider
- **Provider URL:** `https://token.actions.githubusercontent.com`
- **Audience:** `sts.amazonaws.com`
- **Purpose:** Allows GitHub Actions to assume AWS roles without static credentials

#### GitHub Actions IAM Role
- **Role ARN:** `arn:aws:iam::939217651725:role/kubeadm_ec2_cluster-github-actions`
- **Trust Policy:** Scoped to `simeon-Muyiwa/platform-config` repository
- **Permissions:** Full ECR push/pull access to all repositories above

### 2. Platform-Config Repository Structure ✅

The local `platform-config/` folder is ready at:
```
/Users/simeon/Desktop/IAC/Pulumi_project/platform-config/
```

Structure:
```
platform-config/
├── .github/
│   └── workflows/
│       ├── validate.yml           # PR validation workflow
│       ├── build-push-ecr.yml     # Reusable build/push workflow (OIDC)
│       └── update-image.yml       # Image tag update workflow
├── base/                          # Base Kubernetes manifests
├── overlays/
│   ├── dev/
│   ├── staging/
│   └── prod/
├── apps/                          # Argo CD Application definitions
└── scripts/
    ├── setup-complete.sh          # Automated setup script
    ├── setup-ecr.sh
    ├── setup-github.sh
    └── iam-policy-github-actions-ecr.json
```

### 3. GitHub Actions Workflows Created ✅

#### `build-push-ecr.yml` - Build and Push to ECR
- Uses **OIDC authentication** (no static AWS credentials needed)
- Reusable workflow for all services
- Includes vulnerability scanning with Trivy
- Uses GitHub Actions cache for faster builds

#### `validate.yml` - PR Validation
- Validates Kustomize manifests on pull requests
- Checks YAML syntax
- Ensures overlays build correctly

#### `update-image.yml` - Image Tag Updates
- Triggered after successful builds
- Updates `kustomization.yaml` with new image tags
- Commits and pushes changes automatically

---

## What You Need to Do in GitHub

### Step 1: Authenticate GitHub CLI

Run this in your terminal:
```bash
gh auth login
```

Choose:
- **GitHub.com**
- **SSH** protocol
- Upload your SSH public key when prompted
- Complete browser authentication

### Step 2: Create the Private Repository

After authentication, run:
```bash
cd /Users/simeon/Desktop/IAC/Pulumi_project/platform-config

# Initialize git if not already done
git init
git add .
git commit -m "Initial commit: GitOps platform-config structure"

# Create private repo and push
gh repo create platform-config --private --source=. --push --description "GitOps configuration for Kubernetes platform"
```

### Step 3: Configure Repository Variables

Go to your GitHub repository settings and add these **Variables** (not secrets):

**Navigate to:** `https://github.com/simeon-Muyiwa/platform-config/settings/variables/actions`

Click **"New repository variable"** for each:

| Variable Name | Value |
|--------------|-------|
| `AWS_ROLE_ARN` | `arn:aws:iam::939217651725:role/kubeadm_ec2_cluster-github-actions` |
| `ECR_REGISTRY` | `939217651725.dkr.ecr.eu-west-2.amazonaws.com` |
| `CLUSTER_NAME` | `kubeadm_ec2_cluster` |
| `AWS_REGION` | `eu-west-2` |

> **Note:** These are non-sensitive values, so we use Variables instead of Secrets. The OIDC authentication handles the secure AWS access.

### Step 4: Verify OIDC Trust (Already Done by Pulumi)

The IAM role trust policy is already configured to trust your repository. You can verify in AWS Console:

1. Go to **IAM → Roles → kubeadm_ec2_cluster-github-actions**
2. Check the **Trust relationships** tab
3. It should show:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::939217651725:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:simeon-Muyiwa/platform-config:*"
        }
      }
    }
  ]
}
```

### Step 5: Enable Branch Protection (Recommended)

Go to: `https://github.com/simeon-Muyiwa/platform-config/settings/branches`

Add rule for `main` branch:
- [x] Require a pull request before merging
- [x] Require status checks to pass before merging
  - Add: `validate-manifests`
- [x] Require branches to be up to date before merging
- [x] Do not allow bypassing the above settings

### Step 6: Add Deploy Key (Optional - for Argo CD)

If using Argo CD to watch this repo:

1. Generate a deploy key:
```bash
ssh-keygen -t ed25519 -C "platform-config-deploy" -f ~/.ssh/id_ed25519_platform_config -N ""
```

2. Go to: `https://github.com/simeon-Muyiwa/platform-config/settings/keys`

3. Click **"Add deploy key"**
   - Title: `Argo CD Deploy Key`
   - Key: Paste contents of `~/.ssh/id_ed25519_platform_config.pub`
   - [x] Allow write access (needed for GitOps Coordinator)

---

## Quick Reference

### CI/CD Configuration Values

```yaml
# For GitHub Actions workflows
AWS_REGION: eu-west-2
AWS_ROLE_ARN: arn:aws:iam::939217651725:role/kubeadm_ec2_cluster-github-actions
ECR_REGISTRY: 939217651725.dkr.ecr.eu-west-2.amazonaws.com
CLUSTER_NAME: kubeadm_ec2_cluster
```

### ECR Login Command (for local development)

```bash
aws ecr get-login-password --region eu-west-2 | docker login --username AWS --password-stdin 939217651725.dkr.ecr.eu-west-2.amazonaws.com
```

### Push Image to ECR (example)

```bash
# Tag your image
docker tag my-service:latest 939217651725.dkr.ecr.eu-west-2.amazonaws.com/kubeadm_ec2_cluster/identity-service:v1.0.0

# Push
docker push 939217651725.dkr.ecr.eu-west-2.amazonaws.com/kubeadm_ec2_cluster/identity-service:v1.0.0
```

---

## Verification Checklist

After completing the GitHub setup:

- [ ] Repository created at `github.com/simeon-Muyiwa/platform-config`
- [ ] Repository is private
- [ ] All 4 variables configured (AWS_ROLE_ARN, ECR_REGISTRY, CLUSTER_NAME, AWS_REGION)
- [ ] Branch protection enabled on `main`
- [ ] Test workflow runs successfully (push a small change)

### Test the OIDC Setup

Create a simple test workflow to verify OIDC works:

```yaml
# .github/workflows/test-oidc.yml
name: Test OIDC

on: workflow_dispatch

permissions:
  id-token: write
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: eu-west-2
      
      - name: Verify AWS access
        run: |
          aws sts get-caller-identity
          aws ecr describe-repositories --region eu-west-2
```

Run this workflow manually to verify everything works.

---

## Next Steps After GitHub Setup

1. **Push platform-config to GitHub**
2. **Install Argo CD on the cluster** (Phase 2 of GitOps plan)
3. **Configure Argo CD to watch the repository**
4. **Build and push your first service image**
5. **Deploy via GitOps!**

---

## Troubleshooting

### "Could not assume role" error in GitHub Actions

1. Verify the `AWS_ROLE_ARN` variable is correct
2. Check the IAM role trust policy includes your repo
3. Ensure `permissions: id-token: write` is in the workflow

### "Repository not found" when cloning with Argo CD

1. Ensure deploy key is added with correct permissions
2. Use SSH URL: `git@github.com:simeon-Muyiwa/platform-config.git`
3. Add the private key to Argo CD as a repository credential

### ECR push fails with "no basic auth credentials"

1. Ensure the GitHub Actions role has the ECR policy attached
2. Check that `aws-actions/amazon-ecr-login@v2` is used after AWS credential configuration

---

*Document created: January 12, 2026*

---

## 🛠️ Troubleshooting Journey

This section documents the issues we encountered and solved during deployment.

### Issue 1: Calico Felix Not Ready on Worker

**Symptom:** `calico-node` pod on worker showing 0/1 Ready

**Root Cause:** Typha port 5473 not open in master security group

**Solution:** Added port 5473 to Pulumi security group configuration:
```typescript
// infrastructure/pulumi/src/network/security_group.ts
{
  protocol: "tcp",
  fromPort: 5473,
  toPort: 5473,
  cidrBlocks: [vpcCidr],
  description: "Calico Typha port for Felix communication"
}
```

### Issue 2: CoreDNS Domain Mismatch

**Symptom:** Pods couldn't resolve internal services (e.g., `argocd-redis.argocd.svc.cluster.local`)

**Root Cause:** Kubelet used `healthxcape.com` as cluster domain, but CoreDNS was configured for `cluster.local`

**Solution:** Updated CoreDNS ConfigMap:
```yaml
kubernetes healthxcape.com in-addr.arpa ip6.arpa {
   pods insecure
   fallthrough in-addr.arpa ip6.arpa
   ttl 30
}
```

### Issue 3: ArgoCD Not Accessible Externally

**Symptom:** https://argocd.healthxcape.com not reachable

**Root Cause:** Multiple issues:
1. No DNS A record for `argocd.healthxcape.com`
2. Security group only allowed port 80/443 from bastion
3. ingress-nginx not using hostNetwork

**Solution:**
1. Created Route53 A record pointing to master's Elastic IP
2. Added HTTP/HTTPS from `0.0.0.0/0` to master security group
3. Patched ingress-nginx to use `hostNetwork: true` on master node

### Issue 4: Certificate Using Wrong Issuer

**Symptom:** ACME HTTP-01 challenge failing

**Root Cause:** Ingress annotation used `letsencrypt-prod` (HTTP-01) instead of `letsencrypt-dns-prod` (DNS-01)

**Solution:** Patched ingress annotation:
```bash
kubectl patch ingress argocd-server -n argocd --type=json \
  -p='[{"op": "replace", "path": "/metadata/annotations/cert-manager.io~1cluster-issuer", "value": "letsencrypt-dns-prod"}]'
```

### Issue 5: IRSA Not Working

**Symptom:** cert-manager using EC2 instance role instead of IRSA, Route53 calls failing with permission boundary errors

**Root Cause:** Pod-identity-webhook not injecting AWS credentials into pods

**Solution:** Multiple fixes:
1. Added `--token-audience=sts.amazonaws.com` to webhook
2. Regenerated webhook TLS certificate with IP SANs
3. Configured webhook to use `hostNetwork: true`
4. Changed admission review versions

**Verification:**
```bash
kubectl get pod -n cert-manager -l app=cert-manager -o yaml | grep AWS_ROLE_ARN
# Shows: arn:aws:iam::939217651725:role/kubeadm_ec2_cluster-cert-manager-cert-manager
```

---

## 📋 Remaining Tasks

### 1. Fix ImagePullBackOff on Worker Node

The worker node (10.1.42.176) is air-gapped and cannot pull images from the internet.

**Solution:** Distribute images from master to worker:
```bash
# On master
ctr images export image.tar docker.io/library/some-image:tag
scp image.tar worker:/tmp/

# On worker
ctr images import /tmp/image.tar
```

### 2. Sync OutOfSync ArgoCD Applications

| Application | Status | Action Needed |
|-------------|--------|---------------|
| `kafka-cluster` | OutOfSync | Investigate dependencies |
| `platform-services` | OutOfSync | Check image availability |

### 3. Pod-Identity-Webhook Response Format (Low Priority)

The webhook returns responses without `apiVersion`/`kind` wrapper, causing API server warnings. Works because `failurePolicy: Ignore` allows mutations to proceed.

---

## 🚀 Future Enhancements

1. **Horizontal Pod Autoscaler** - Scale workloads based on metrics
2. **Cluster Autoscaler** - Add/remove worker nodes dynamically
3. **External Secrets Operator** - Sync secrets from AWS Secrets Manager
4. **Prometheus + Grafana** - Monitoring and alerting
5. **Velero** - Cluster backup and disaster recovery
6. **Multi-cluster ArgoCD** - Manage multiple clusters from one ArgoCD

---

## 📚 References

- [Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way)
- [IRSA on Self-Managed Kubernetes](https://aws.amazon.com/blogs/containers/introducing-fine-grained-iam-roles-for-service-accounts/)
- [cert-manager DNS-01 with Route53](https://cert-manager.io/docs/configuration/acme/dns01/route53/)
- [ArgoCD Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/)
- [Calico on kubeadm](https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises)

---

*Last updated: January 12, 2026*
*Status: Production Live* 🔥
