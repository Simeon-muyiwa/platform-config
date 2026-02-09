# GitOps ECR Setup Guide

## Overview

This guide details the ECR and GitHub Actions OIDC setup for our GitOps-first CI/CD environment using:

- **Pulumi (TypeScript)** for AWS infrastructure (ECR, IAM, OIDC)
- **Ansible** for kubeadm node configuration
- **GitHub Actions** for CI (build & push to ECR)
- **Argo CD** for GitOps deployment (platform-config is the single source of truth)

**Key Principle:**  
All workload changes flow through **Git (platform-config)** and are applied by **Argo CD**. CI **must not** call `kubectl` directly for normal deployments.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              GitHub Actions CI                               │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────────────┐  │
│  │ Service Repo │───▶│ Build Image  │───▶│  Push to ECR (OIDC Auth)     │  │
│  └──────────────┘    └──────────────┘    └──────────────────────────────┘  │
│                                                        │                     │
│                                                        ▼                     │
│                                          ┌──────────────────────────────┐   │
│                                          │ Update platform-config repo  │   │
│                                          │ (kustomization.yaml images)  │   │
│                                          └──────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                                         │
                                                         ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Argo CD (GitOps)                                │
│  ┌──────────────────┐         ┌──────────────────┐         ┌─────────────┐ │
│  │ Watch platform-  │────────▶│  Detect Changes  │────────▶│ Sync to K8s │ │
│  │ config repo      │         │                  │         │             │ │
│  └──────────────────┘         └──────────────────┘         └─────────────┘ │
└─────────────────────────────────────────────────────────────────────────────┘
                                                         │
                                                         ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          kubeadm Cluster (EC2)                               │
│  ┌────────────┐    ┌────────────┐    ┌────────────────────────────────────┐│
│  │  Master    │    │  Workers   │───▶│  Pull from ECR (IAM Instance Role) ││
│  └────────────┘    └────────────┘    └────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## What Pulumi Creates

### ECR Repositories

| Repository | Purpose |
|------------|---------|
| `{cluster}/webapp-operator` | Ansible-based Kubernetes operator |
| `{cluster}/identity-service` | Auth/JWT NestJS service |
| `{cluster}/user-service` | User profile NestJS service |
| `{cluster}/blog-service` | Blog content NestJS service |
| `{cluster}/frontend` | Next.js frontend |
| `{cluster}/gitops-coordinator` | GitOps orchestration service |

### IAM Resources

| Resource | Purpose |
|----------|---------|
| GitHub OIDC Provider | Federated identity for GitHub Actions |
| GitHub Actions Role | Assumes via OIDC, has ECR push permissions |
| Worker Instance Profile | EC2 role with ECR pull permissions |

---

## Step 1: Deploy Infrastructure

```bash
cd infrastructure/pulumi

# Preview changes
pulumi preview

# Deploy ECR + IAM resources
pulumi up

# Export outputs for reference
pulumi stack output --json > pulumi-outputs.json
```

### Key Outputs

After deployment, you'll have these exports:

```bash
# Get GitHub Actions role ARN (for repository secrets)
pulumi stack output githubActionsRoleArn

# Get ECR registry URL
pulumi stack output ecrRegistry

# Get all ECR repository URLs
pulumi stack output ecrRepositoryUrls

# Get full CI/CD config
pulumi stack output cicdConfig
```

---

## Step 2: Configure GitHub Repository Secrets

Add these secrets to your **service repositories** (identity-service, user-service, etc.):

| Secret Name | Value | Source |
|-------------|-------|--------|
| `AWS_ROLE_ARN` | GitHub Actions role ARN | `pulumi stack output githubActionsRoleArn` |
| `AWS_REGION` | AWS region | `eu-west-2` (or your region) |
| `PLATFORM_CONFIG_SSH_KEY` | Deploy key private key | See Step 6 |

---

## Step 3: GitHub Actions Workflow (GitOps-Correct)

Create `.github/workflows/build-push.yml` in each service repository:

```yaml
name: Build and Push to ECR

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  AWS_REGION: eu-west-2
  SERVICE_NAME: identity-service  # Change per service

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      id-token: write   # Required for OIDC
      contents: read

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build, tag, and push image
        id: build
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          CLUSTER_NAME: kubeadm_ec2_cluster  # From Pulumi config
          IMAGE_TAG: ${{ github.sha }}
        run: |
          IMAGE_URI=$ECR_REGISTRY/$CLUSTER_NAME/$SERVICE_NAME
          
          docker build -t $IMAGE_URI:$IMAGE_TAG .
          docker tag $IMAGE_URI:$IMAGE_TAG $IMAGE_URI:latest
          
          docker push $IMAGE_URI:$IMAGE_TAG
          docker push $IMAGE_URI:latest
          
          echo "image=$IMAGE_URI:$IMAGE_TAG" >> $GITHUB_OUTPUT

      # =========================================================
      # GitOps: Update platform-config instead of kubectl apply
      # =========================================================
      - name: Setup SSH for platform-config
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
        uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.PLATFORM_CONFIG_SSH_KEY }}

      - name: Update platform-config
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
        env:
          IMAGE_TAG: ${{ github.sha }}
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          CLUSTER_NAME: kubeadm_ec2_cluster
        run: |
          git clone git@github.com:${{ github.repository_owner }}/platform-config.git
          cd platform-config
          
          # Update image in prod overlay
          cd overlays/prod
          
          # Update kustomization.yaml with new image tag
          yq -i '(.images[] | select(.name == "'$SERVICE_NAME'")).newTag = "'$IMAGE_TAG'"' kustomization.yaml
          yq -i '(.images[] | select(.name == "'$SERVICE_NAME'")).newName = "'$ECR_REGISTRY/$CLUSTER_NAME/$SERVICE_NAME'"' kustomization.yaml
          
          # Commit and push
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add .
          git diff --staged --quiet || git commit -m "deploy($SERVICE_NAME): update to $IMAGE_TAG"
          git push origin main
```

### Why No kubectl?

- **Argo CD is the single reconciler** - it watches platform-config and syncs to the cluster
- **No drift** - CI doesn't directly modify cluster state
- **Audit trail** - every deployment is a Git commit
- **Rollback** - git revert to any previous state

---

## Step 4: Worker Nodes ECR Access

Worker nodes already have ECR pull permissions via their IAM instance profile. 

**Verification (on a worker node):**

```bash
# Check IAM role
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/

# Test ECR access
aws ecr get-login-password --region eu-west-2 | docker login --username AWS --password-stdin <account-id>.dkr.ecr.eu-west-2.amazonaws.com
```

**Kubernetes manifests don't need imagePullSecrets:**

```yaml
# No imagePullSecrets needed - IAM handles auth
spec:
  containers:
    - name: app
      image: 123456789.dkr.ecr.eu-west-2.amazonaws.com/kubeadm_ec2_cluster/identity-service:abc123
```

---

## Step 5: Argo CD Configuration

Configure Argo CD to watch `platform-config`:

```yaml
# argocd-cm ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  repositories: |
    - url: git@github.com:your-org/platform-config.git
      sshPrivateKeySecret:
        name: platform-config-ssh
        key: sshPrivateKey
```

Argo CD Application pointing to overlays:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: identity-service
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:your-org/platform-config.git
    targetRevision: main
    path: overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      selfHeal: true
      prune: false  # Safety: don't auto-delete
```

---

## Step 6: SSH Deploy Keys for Cross-Repo Writes

Generate a deploy key so service repos can update `platform-config`:

```bash
# Generate key pair
ssh-keygen -t ed25519 -C "github-actions-deploy-key" \
  -f ~/.ssh/platform-config-deploy-key -N ""

# Show public key (add to platform-config repo)
cat ~/.ssh/platform-config-deploy-key.pub

# Show private key (add as secret to service repos)
cat ~/.ssh/platform-config-deploy-key
```

**Setup:**

1. **platform-config repo** → Settings → Deploy keys → Add key
   - Paste public key
   - ✅ Enable "Allow write access"

2. **Each service repo** → Settings → Secrets → Actions → New secret
   - Name: `PLATFORM_CONFIG_SSH_KEY`
   - Value: Private key contents

---

## Step 7: Verify Setup

### Test ECR Push (Manual)

```bash
# Configure AWS CLI with your credentials
aws configure

# Login to ECR
aws ecr get-login-password --region eu-west-2 | \
  docker login --username AWS --password-stdin \
  $(pulumi stack output ecrRegistry)

# Build and push a test image
docker build -t $(pulumi stack output ecrRegistry)/kubeadm_ec2_cluster/identity-service:test .
docker push $(pulumi stack output ecrRegistry)/kubeadm_ec2_cluster/identity-service:test
```

### Test GitHub Actions OIDC

Create a test workflow:

```yaml
name: Test AWS OIDC
on: workflow_dispatch

jobs:
  test:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: eu-west-2
      
      - run: aws sts get-caller-identity
      - run: aws ecr describe-repositories
```

---

## Ansible Integration

The dynamic inventory now includes ECR configuration:

```bash
# Generate inventory with ECR info
cd infrastructure/pulumi
pulumi stack output ansibleInventory --json > ../../pulumi-outputs.json

# Run inventory script
cd ../../scripts/inventory
./dynamic_inventory2.py ../../pulumi-outputs.json
```

**Available variables in Ansible:**

```yaml
# ECR Configuration
ecr_registry_url: "123456789.dkr.ecr.eu-west-2.amazonaws.com"
ecr_repositories:
  identity-service: "123456789.dkr.ecr.eu-west-2.amazonaws.com/kubeadm_ec2_cluster/identity-service"
  user-service: "123456789.dkr.ecr.eu-west-2.amazonaws.com/kubeadm_ec2_cluster/user-service"
  # ... etc

# CI/CD Configuration  
github_actions_role_arn: "arn:aws:iam::123456789:role/kubeadm_ec2_cluster-github-actions"
cicd_ecr_registry: "123456789.dkr.ecr.eu-west-2.amazonaws.com"
```

---

## Future: GitOps Coordinator Integration

Once the GitOps Coordinator is ready, replace the "Update platform-config" step with:

```yaml
- name: Publish Deployment Event to Kafka
  run: |
    echo '{
      "eventType": "DEPLOYMENT_REQUESTED",
      "correlationId": "gh-${{ github.run_id }}",
      "service": {
        "name": "'$SERVICE_NAME'",
        "image": "'${{ steps.build.outputs.image }}'"
      },
      "environment": "prod"
    }' | kafkacat -P -b $KAFKA_BROKERS -t cicd-deployment-events
```

The coordinator will then:
1. Receive the Kafka event
2. Update platform-config (single writer pattern)
3. Trigger Argo CD sync
4. Publish status back to Kafka

---

## Summary

| Component | Status | Notes |
|-----------|--------|-------|
| ECR Repositories | ✅ Created | 6 repos with lifecycle policies |
| GitHub OIDC | ✅ Configured | Federated identity, no static keys |
| GitHub Actions Role | ✅ Created | ECR push permissions attached |
| Worker ECR Pull | ✅ Ready | Via IAM instance profile |
| Dynamic Inventory | ✅ Updated | ECR URLs available in Ansible |
| platform-config | 🔲 Next | Create private repo with deploy keys |
| Argo CD | 🔲 Phase 2 | Install and configure |
| GitOps Coordinator | 🔲 Phase 3 | Replace direct Git updates |

---

## Troubleshooting

### OIDC Trust Issues

```bash
# Check OIDC provider exists
aws iam list-open-id-connect-providers

# Verify thumbprint
aws iam get-open-id-connect-provider --open-id-connect-provider-arn <arn>
```

### ECR Authentication Failures

```bash
# Worker node - check instance profile
curl http://169.254.169.254/latest/meta-data/iam/security-credentials/

# GitHub Actions - verify role assumption
aws sts get-caller-identity
```

### Image Pull Errors

```bash
# Verify image exists
aws ecr describe-images --repository-name kubeadm_ec2_cluster/identity-service

# Check worker can pull
kubectl run test --image=<ecr-url>/identity-service:latest --rm -it --restart=Never -- /bin/sh
```

---

*Document Version: 1.0*  
*Last Updated: January 12, 2026*
