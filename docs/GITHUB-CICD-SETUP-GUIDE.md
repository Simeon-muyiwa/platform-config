# GitHub CI/CD + GitOps Setup Guide

## Overview

This document provides a comprehensive guide on how we set up our GitHub-based CI/CD pipeline with OIDC authentication to AWS ECR. This is **Phase 2 Part 1** of our GitOps implementation plan.

**Date Completed:** January 12, 2026  
**Completed By:** Platform Team  
**Repository:** https://github.com/Simeon-muyiwa/platform-config

---

## Table of Contents

1. [What We Built](#1-what-we-built)
2. [Architecture Overview](#2-architecture-overview)
3. [Infrastructure Created (Pulumi)](#3-infrastructure-created-pulumi)
4. [GitHub Repository Setup](#4-github-repository-setup)
5. [GitHub Actions Workflows](#5-github-actions-workflows)
6. [How OIDC Authentication Works](#6-how-oidc-authentication-works)
7. [Step-by-Step Reproduction Guide](#7-step-by-step-reproduction-guide)
8. [Repository Variables Reference](#8-repository-variables-reference)
9. [Testing the Setup](#9-testing-the-setup)
10. [Known Limitations](#10-known-limitations)
11. [Next Steps](#11-next-steps)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. What We Built

We established a secure, credential-free CI/CD pipeline that:

- ✅ Uses **GitHub OIDC** to authenticate with AWS (no static credentials stored)
- ✅ Pushes container images to **AWS ECR** (Elastic Container Registry)
- ✅ Updates Kubernetes manifests in a **GitOps-style** workflow
- ✅ Validates all Pull Requests with Kustomize before merge
- ✅ Provides a structured **platform-config** repository for GitOps

### Key Benefits

| Feature | Benefit |
|---------|---------|
| OIDC Authentication | No AWS access keys to rotate or manage |
| Reusable Workflows | DRY principle - one workflow for all services |
| Kustomize Overlays | Environment-specific configurations (dev/staging/prod) |
| ECR Integration | Private container registry with automatic cleanup |

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           GitHub Actions                                 │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐     │
│  │   validate.yml  │    │build-push-ecr.yml│    │update-image.yml │     │
│  │  (PR Checks)    │    │ (Build & Push)  │    │ (Update Tags)   │     │
│  └────────┬────────┘    └────────┬────────┘    └────────┬────────┘     │
│           │                      │                      │               │
└───────────┼──────────────────────┼──────────────────────┼───────────────┘
            │                      │                      │
            │                      ▼                      │
            │         ┌────────────────────────┐         │
            │         │  GitHub OIDC Provider  │         │
            │         │  (token.actions.       │         │
            │         │   githubusercontent.com)│         │
            │         └───────────┬────────────┘         │
            │                     │                      │
            │                     ▼                      │
            │         ┌────────────────────────┐         │
            │         │   AWS IAM Role         │         │
            │         │   (github-actions)     │         │
            │         │   Trust: OIDC Provider │         │
            │         └───────────┬────────────┘         │
            │                     │                      │
            ▼                     ▼                      ▼
┌─────────────────┐   ┌─────────────────────┐   ┌─────────────────┐
│ platform-config │   │     AWS ECR         │   │ Kubernetes      │
│   Repository    │   │ (6 repositories)    │   │ Cluster         │
│   (Git source   │   │ - webapp-operator   │   │ (kubeadm EC2)   │
│    of truth)    │   │ - identity-service  │   │                 │
│                 │   │ - user-service      │   │                 │
│                 │   │ - blog-service      │   │                 │
│                 │   │ - frontend          │   │                 │
│                 │   │ - gitops-coordinator│   │                 │
└─────────────────┘   └─────────────────────┘   └─────────────────┘
```

---

## 3. Infrastructure Created (Pulumi)

All AWS infrastructure was created using **Pulumi** (TypeScript). The relevant code is in:

```
infrastructure/pulumi/
├── shared.ts          # GitHub OIDC + ECR repositories
├── iam_roles.ts       # IAM roles for IRSA
└── Pulumi.dev.yaml    # Configuration values
```

### 3.1 ECR Repositories

Six ECR repositories were created with the naming pattern `{cluster_name}-{service}`:

| Repository | Full Name |
|------------|-----------|
| webapp-operator | `kubeadm_ec2_cluster-webapp-operator` |
| identity-service | `kubeadm_ec2_cluster-identity-service` |
| user-service | `kubeadm_ec2_cluster-user-service` |
| blog-service | `kubeadm_ec2_cluster-blog-service` |
| frontend | `kubeadm_ec2_cluster-frontend` |
| gitops-coordinator | `kubeadm_ec2_cluster-gitops-coordinator` |

**Registry URL:** `939217651725.dkr.ecr.eu-west-2.amazonaws.com`

### 3.2 GitHub OIDC Provider

An OIDC identity provider was created in AWS IAM:

```typescript
// From shared.ts
const githubOidcProvider = new aws.iam.OpenIdConnectProvider("github-oidc", {
    url: "https://token.actions.githubusercontent.com",
    clientIdLists: ["sts.amazonaws.com"],
    thumbprintLists: ["ffffffffffffffffffffffffffffffffffffffff"],
});
```

### 3.3 GitHub Actions IAM Role

An IAM role that GitHub Actions can assume via OIDC:

**Role Name:** `kubeadm_ec2_cluster-github-actions`  
**Role ARN:** `arn:aws:iam::939217651725:role/kubeadm_ec2_cluster-github-actions`

**Trust Policy:**
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
          "token.actions.githubusercontent.com:sub": "repo:Simeon-muyiwa/platform-config:*"
        }
      }
    }
  ]
}
```

**Attached Policy (ECR Permissions):**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeRepositories",
        "ecr:ListImages"
      ],
      "Resource": "*"
    }
  ]
}
```

### 3.4 Pulumi Configuration Set

The following config values were set in Pulumi:

```bash
pulumi config set kube-cluster-deployment:githubOrg "Simeon-muyiwa"
pulumi config set kube-cluster-deployment:githubRepo "platform-config"
```

---

## 4. GitHub Repository Setup

### 4.1 Repository Creation

The repository was created using GitHub CLI:

```bash
# Navigate to platform-config directory
cd /Users/simeon/Desktop/IAC/Pulumi_project/platform-config

# Initialize git and create initial commit
git init
git add .
git commit -m "Initial commit: GitOps platform configuration"

# Create private repository and push
gh repo create platform-config --private --source=. --push \
  --description "GitOps platform configuration for kubeadm K8s cluster"
```

### 4.2 SSH Key Configuration

The SSH key was uploaded to GitHub for authentication:

```bash
# Add SSH key to ssh-agent (required for Git operations)
ssh-add ~/.ssh/bastion-key-new
```

### 4.3 Repository Structure

```
platform-config/
├── .github/
│   └── workflows/
│       ├── validate.yml          # PR validation
│       ├── build-push-ecr.yml    # Reusable: Build & push to ECR
│       └── update-image.yml      # Update image tags in overlays
├── apps/                         # Argo CD Application definitions
│   ├── app-of-apps.yaml
│   ├── operator-app.yaml
│   ├── kafka-app.yaml
│   └── platform-services-app.yaml
├── base/                         # Base Kubernetes manifests
│   ├── operator/
│   ├── identity-service/
│   ├── user-service/
│   ├── blog-service/
│   ├── frontend/
│   └── kafka/
├── overlays/                     # Environment-specific configs
│   ├── dev/
│   ├── staging/
│   └── prod/
└── scripts/                      # Utility scripts
    ├── validate.sh
    ├── bootstrap.sh
    └── setup-complete.sh
```

---

## 5. GitHub Actions Workflows

### 5.1 Validate Workflow (`validate.yml`)

**Purpose:** Validates all PRs before merge by checking Kustomize builds.

**Trigger:** Pull requests to `main` branch

```yaml
name: Validate Manifests

on:
  pull_request:
    branches: [main]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup Kustomize
        uses: imranismail/setup-kustomize@v2
      
      - name: Validate Dev Overlay
        run: kustomize build overlays/dev > /dev/null
      
      - name: Validate Staging Overlay
        run: kustomize build overlays/staging > /dev/null
      
      - name: Validate Prod Overlay
        run: kustomize build overlays/prod > /dev/null
```

### 5.2 Build & Push Workflow (`build-push-ecr.yml`)

**Purpose:** Reusable workflow for building Docker images and pushing to ECR.

**Key Features:**
- Uses OIDC for AWS authentication (no secrets needed)
- Accepts service name and Dockerfile path as inputs
- Tags images with both `latest` and specific version

```yaml
name: Build and Push to ECR

on:
  workflow_call:
    inputs:
      service-name:
        required: true
        type: string
      dockerfile-path:
        required: false
        type: string
        default: './Dockerfile'
      context-path:
        required: false
        type: string
        default: '.'
      image-tag:
        required: false
        type: string
        default: ''

jobs:
  build-push:
    runs-on: ubuntu-latest
    permissions:
      id-token: write   # Required for OIDC
      contents: read

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS Credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: ${{ vars.AWS_REGION }}

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and Push Image
        env:
          ECR_REGISTRY: ${{ vars.ECR_REGISTRY }}
          IMAGE_TAG: ${{ inputs.image-tag || github.sha }}
          CLUSTER_NAME: ${{ vars.CLUSTER_NAME }}
        run: |
          REPO_NAME="${CLUSTER_NAME}-${{ inputs.service-name }}"
          FULL_IMAGE="${ECR_REGISTRY}/${REPO_NAME}"
          
          docker build -t ${FULL_IMAGE}:${IMAGE_TAG} \
                       -t ${FULL_IMAGE}:latest \
                       -f ${{ inputs.dockerfile-path }} \
                       ${{ inputs.context-path }}
          
          docker push ${FULL_IMAGE}:${IMAGE_TAG}
          docker push ${FULL_IMAGE}:latest
```

### 5.3 Update Image Workflow (`update-image.yml`)

**Purpose:** Updates image tags in Kustomize overlays (for GitOps flow).

```yaml
name: Update Image Tag

on:
  workflow_dispatch:
    inputs:
      service:
        description: 'Service to update'
        required: true
        type: choice
        options:
          - identity-service
          - user-service
          - blog-service
          - frontend
          - webapp-operator
      tag:
        description: 'New image tag'
        required: true
        type: string
      environment:
        description: 'Target environment'
        required: true
        type: choice
        options:
          - dev
          - staging
          - prod

jobs:
  update:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          token: ${{ secrets.GITHUB_TOKEN }}

      - name: Setup Kustomize
        uses: imranismail/setup-kustomize@v2

      - name: Update Image Tag
        env:
          ECR_REGISTRY: ${{ vars.ECR_REGISTRY }}
          CLUSTER_NAME: ${{ vars.CLUSTER_NAME }}
        run: |
          cd overlays/${{ inputs.environment }}
          REPO_NAME="${CLUSTER_NAME}-${{ inputs.service }}"
          kustomize edit set image \
            ${{ inputs.service }}=${ECR_REGISTRY}/${REPO_NAME}:${{ inputs.tag }}

      - name: Commit and Push
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add .
          git commit -m "chore(${{ inputs.environment }}): Update ${{ inputs.service }} to ${{ inputs.tag }}"
          git push
```

---

## 6. How OIDC Authentication Works

### The Flow

```
1. GitHub Actions workflow starts
         │
         ▼
2. Workflow requests OIDC token from GitHub
   (contains claims about repo, branch, etc.)
         │
         ▼
3. Workflow calls AWS STS AssumeRoleWithWebIdentity
   with the GitHub OIDC token
         │
         ▼
4. AWS validates token against configured OIDC provider
   - Checks issuer: token.actions.githubusercontent.com
   - Checks audience: sts.amazonaws.com
   - Checks subject: repo:Simeon-muyiwa/platform-config:*
         │
         ▼
5. If valid, AWS returns temporary credentials
   (valid for ~1 hour)
         │
         ▼
6. Workflow uses credentials to interact with ECR
```

### Why OIDC is Better Than Access Keys

| Aspect | Access Keys | OIDC |
|--------|-------------|------|
| Credential Rotation | Manual rotation needed | Automatic (per-job) |
| Exposure Risk | Can be leaked in logs | No long-lived secrets |
| Scope | Broad (account-level) | Scoped to specific repo |
| Audit | Harder to trace | Clear identity in CloudTrail |
| Management | Store in GitHub Secrets | No secrets needed |

---

## 7. Step-by-Step Reproduction Guide

If you need to recreate this setup for a new environment:

### Step 1: Install Prerequisites

```bash
# Install GitHub CLI
brew install gh

# Authenticate with GitHub
gh auth login --web --git-protocol ssh
```

### Step 2: Update Pulumi Configuration

```bash
cd /path/to/infrastructure/pulumi

# Set GitHub org and repo
pulumi config set kube-cluster-deployment:githubOrg "YOUR-GITHUB-USERNAME"
pulumi config set kube-cluster-deployment:githubRepo "YOUR-REPO-NAME"

# Apply changes
pulumi up
```

### Step 3: Create GitHub Repository

```bash
cd /path/to/platform-config

# Initialize and push
git init
git add .
git commit -m "Initial commit"
gh repo create YOUR-REPO-NAME --private --source=. --push
```

### Step 4: Configure Repository Variables

```bash
# Set all required variables
gh variable set AWS_ROLE_ARN --body "arn:aws:iam::ACCOUNT_ID:role/CLUSTER-github-actions"
gh variable set ECR_REGISTRY --body "ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com"
gh variable set CLUSTER_NAME --body "YOUR_CLUSTER_NAME"
gh variable set AWS_REGION --body "YOUR_AWS_REGION"
```

### Step 5: Add SSH Key to Agent

```bash
ssh-add ~/.ssh/YOUR_KEY
```

---

## 8. Repository Variables Reference

These variables are configured at the repository level in GitHub:

| Variable | Value | Purpose |
|----------|-------|---------|
| `AWS_ROLE_ARN` | `arn:aws:iam::939217651725:role/kubeadm_ec2_cluster-github-actions` | IAM role for OIDC auth |
| `ECR_REGISTRY` | `939217651725.dkr.ecr.eu-west-2.amazonaws.com` | ECR registry URL |
| `CLUSTER_NAME` | `kubeadm_ec2_cluster` | Cluster name (prefix for ECR repos) |
| `AWS_REGION` | `eu-west-2` | AWS region |

**To view current variables:**
```bash
gh variable list --repo Simeon-muyiwa/platform-config
```

**To update a variable:**
```bash
gh variable set VARIABLE_NAME --body "new-value" --repo Simeon-muyiwa/platform-config
```

---

## 9. Testing the Setup

### Test 1: Validate Workflow

Create a PR to test the validation workflow:

```bash
cd platform-config
git checkout -b test/validation
echo "# Test" >> README.md
git add . && git commit -m "test: trigger validation"
git push -u origin test/validation
gh pr create --title "Test Validation" --body "Testing workflows"
```

Check GitHub Actions tab for the validation run.

### Test 2: Manual Image Update

Trigger the update-image workflow manually:

1. Go to https://github.com/Simeon-muyiwa/platform-config/actions
2. Select "Update Image Tag"
3. Click "Run workflow"
4. Fill in: service=`identity-service`, tag=`v1.0.0`, environment=`dev`
5. Click "Run workflow"

### Test 3: Build and Push (when code exists)

Once you have service code, test the build workflow:

```yaml
# In your service's workflow file
jobs:
  build:
    uses: Simeon-muyiwa/platform-config/.github/workflows/build-push-ecr.yml@main
    with:
      service-name: identity-service
      dockerfile-path: ./Dockerfile
      context-path: .
```

---

## 10. Current Configuration

### ✅ Repository is PUBLIC

The `platform-config` repository was made **public** to enable branch protection without requiring GitHub Pro.

**Why this is safe:**
- Contains only Kubernetes manifests (no secrets)
- Kustomize overlays are environment-agnostic templates
- Argo CD Application definitions don't contain credentials
- GitHub Actions use OIDC (no secrets in workflows)
- This is a common pattern for GitOps config repos

### ✅ Branch Protection Enabled

Branch protection is configured on `main`:
- **Required status checks**: `validate` workflow must pass
- **Strict mode**: Branch must be up to date before merging

### Remaining Considerations

- ECR image scanning not yet configured
- No automatic image cleanup policy (images accumulate)
- Workflows are not yet connected to actual service builds

### If You Need Private Later

If you later need to make the repository private:
```bash
# Requires GitHub Pro ($4/month)
gh repo edit Simeon-muyiwa/platform-config --visibility private
```

---

## 11. Next Steps

### Immediate Next Step: Install Argo CD

The next phase is to install Argo CD on the Kubernetes cluster:

```bash
# Create namespace
kubectl create namespace argocd

# Install Argo CD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for pods
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=300s

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

### Phase 2 Remaining Tasks

- [ ] Install Argo CD on cluster
- [ ] Configure Argo CD to watch `platform-config` repository
- [ ] Set up App-of-Apps pattern
- [ ] Create Ingress for Argo CD UI (argocd.healthxcape.com)
- [ ] Configure SSO for Argo CD (optional)

### Phase 3 Preview

- [ ] Implement GitOps Coordinator service
- [ ] Set up CI/CD Kafka topics
- [ ] Configure event-driven deployments

---

## 12. Troubleshooting

### Issue: SSH Permission Denied

**Error:** `git@github.com: Permission denied (publickey)`

**Solution:**
```bash
# Add SSH key to agent
ssh-add ~/.ssh/bastion-key-new

# Verify
ssh -T git@github.com
# Should output: "Hi Simeon-muyiwa! You've successfully authenticated..."
```

### Issue: OIDC Role Assumption Failed

**Error:** `Error: Could not assume role with OIDC`

**Check:**
1. Verify the trust policy includes your repo:
   ```bash
   aws iam get-role --role-name kubeadm_ec2_cluster-github-actions \
     --query 'Role.AssumeRolePolicyDocument'
   ```

2. Ensure `id-token: write` permission is in workflow:
   ```yaml
   permissions:
     id-token: write
     contents: read
   ```

3. Verify repository variables are set correctly

### Issue: ECR Login Failed

**Error:** `Error: Cannot perform an interactive login from a non TTY device`

**Solution:** Ensure you're using the `aws-actions/amazon-ecr-login@v2` action, not manual login.

### Issue: Kustomize Build Fails

**Error:** `Error: unable to find...`

**Check:**
```bash
# Validate locally
cd platform-config
kustomize build overlays/dev
kustomize build overlays/staging
kustomize build overlays/prod
```

---

## Quick Reference

### Key URLs

| Resource | URL |
|----------|-----|
| GitHub Repository | https://github.com/Simeon-muyiwa/platform-config |
| ECR Console | https://eu-west-2.console.aws.amazon.com/ecr/repositories?region=eu-west-2 |
| IAM Role | https://console.aws.amazon.com/iam/home#/roles/kubeadm_ec2_cluster-github-actions |
| GitHub Actions | https://github.com/Simeon-muyiwa/platform-config/actions |

### Key Commands

```bash
# Check GitHub auth status
gh auth status

# List repo variables
gh variable list --repo Simeon-muyiwa/platform-config

# View workflow runs
gh run list --repo Simeon-muyiwa/platform-config

# Get ECR repos
aws ecr describe-repositories --query 'repositories[*].repositoryName'

# Test SSH connection
ssh -T git@github.com
```

---

**Document Maintainer:** Platform Team  
**Last Updated:** January 12, 2026  
**Version:** 1.0
