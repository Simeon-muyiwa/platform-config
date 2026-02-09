# GitOps Implementation Plan

## Executive Summary

This document details the phased implementation plan to evolve our current operator-based microservices platform into a full GitOps production deployment using Argo CD, Kafka-based orchestration, and a GitOps Coordinator service.

**Current State:** Minikube-based development with Ansible operator, CRDs, and Kafka event-driven services  
**Target State:** Production-ready GitOps with Argo CD, centralized configuration, and automated deployment orchestration

---

## Related Documents

| Document | Purpose |
|----------|---------|
| [gitops-workout.md](../gitops-workout.md) | Comprehensive blueprint with full code examples |
| [gitops-testing.md](../gitops-testing.md) | Testing strategy: unit → chaos engineering |
| [SESSION-WORKFLOW-DOCUMENTATION.md](../SESSION-WORKFLOW-DOCUMENTATION.md) | Session notes, issues, and solutions |

---

## Table of Contents

1. [Current Architecture Inventory](#1-current-architecture-inventory)
2. [Phase 1: Production Infrastructure Preparation](#2-phase-1-production-infrastructure-preparation)
3. [Phase 2: GitOps Foundation](#3-phase-2-gitops-foundation)
4. [Phase 3: Orchestration Layer](#4-phase-3-orchestration-layer)
5. [Phase 4: Advanced Operations](#5-phase-4-advanced-operations)
6. [Implementation Timeline](#6-implementation-timeline)
7. [Risk Mitigation](#7-risk-mitigation)
8. [Zero-Redeploy Configuration Pattern](#8-zero-redeploy-configuration-pattern)
9. [Self-Governing Architecture (Spec-Kits)](#9-self-governing-architecture-spec-kits)

---

## 1. Current Architecture Inventory

### 1.1 What We Have

#### Custom Resources (CRDs)
| CRD | Purpose | Operator Role |
|-----|---------|---------------|
| `IdentityService` | Auth/JWT management | `identityservice` |
| `UserService` | Profile management | `userservice` |
| `BlogService` | Blog content | `blogservice` |
| `KafkaCluster` | Strimzi/Kafka deployment | `kafkacluster` |
| `Frontend` | Next.js UI | `frontend` |
| `AuthService` | Legacy coupled auth | `authservice` |
| `WebApp` | Simple webapp | `webapp` |

#### Kafka Topics (Strimzi/KRaft)
- `identity.events` - Identity domain events
- `user.events` - User/profile events  
- `blog.events` - Blog domain events
- `platform-dlq` - Dead letter queue

#### Services Architecture
```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ identity-service│────▶│   Kafka         │◀────│  user-service   │
│   (NestJS)      │     │ (Strimzi/KRaft) │     │   (NestJS)      │
└─────────────────┘     └─────────────────┘     └─────────────────┘
         │                       ▲                       │
         │                       │                       │
         ▼                       │                       ▼
┌─────────────────┐              │              ┌─────────────────┐
│   PostgreSQL    │              │              │   PostgreSQL    │
│   + Redis       │              │              │                 │
└─────────────────┘              │              └─────────────────┘
                                 │
                    ┌────────────┴────────────┐
                    │      blog-service       │
                    │        (NestJS)         │
                    └─────────────────────────┘
```

#### Operator Stack
- **Operator SDK**: Ansible-based
- **Reconciliation**: Role per CR type
- **Deployment**: `webapp-operator-system` namespace
- **Current Version**: v1.0.8

### 1.2 What We're Keeping
- ✅ All CRDs - they become the declarative interface
- ✅ Ansible operator - it remains the reconciler
- ✅ Kafka infrastructure - extends to CI/CD events
- ✅ NestJS services - no code changes needed
- ✅ `@platform/kafka` shared library

### 1.3 What We're Adding
- 🆕 `platform-config` Git repository
- 🆕 Argo CD for GitOps reconciliation
- 🆕 GitOps Coordinator service
- 🆕 CI/CD Kafka topics
- 🆕 Centralized `rules.json` configuration
- 🆕 Health Check Aggregator

---

## 2. Phase 1: Production Infrastructure Preparation

**Duration:** ~~1-2 weeks~~ ✅ **ALREADY COMPLETE**  
**Goal:** ~~Prepare production cluster and migrate from Minikube~~ **DONE**

> **Status:** Our infrastructure automation is fully operational. One command deploys the entire production-ready platform.

### 2.1 Production Cluster Setup

#### Our Approach: Self-managed kubeadm on EC2 (Cloud Agnostic)

We use a self-managed kubeadm cluster on EC2 for **cloud agnosticism** - the platform can be deployed to any cloud or on-premises infrastructure with minimal changes.

**Single Command Deployment:**
```bash
# Deploys entire platform including:
# - Kubernetes cluster (kubeadm)
# - Calico networking
# - IRSA/OIDC authentication
# - Cert-manager with Let's Encrypt
# - All platform components
make deploy-irsa-platform
```

**Infrastructure Components (Pulumi + Ansible):**
```
infrastructure/
├── pulumi/                    # EC2 instances, VPC, IAM, OIDC provider
└── packer/                    # Pre-baked AMIs (optional)

ansible/playbooks/
├── cluster-init.yml           # kubeadm cluster initialization
├── deploy-aws-ccm.yml         # AWS Cloud Controller Manager
├── deploy-calico.yml          # CNI networking (or prebaked)
├── deploy-irsa-platform.yml   # IRSA + OIDC discovery
├── deploy-certificate-management.yml  # Cert-manager + Let's Encrypt
└── deploy-platform-complete.yml       # Full platform deployment
```

**Why NOT EKS:**
| Consideration | EKS | Our kubeadm Approach |
|--------------|-----|---------------------|
| Cloud lock-in | AWS-specific | Cloud agnostic ✅ |
| Control plane | AWS managed | Self-managed (full control) ✅ |
| Cost | ~$73/month per cluster | EC2 only ✅ |
| Customization | Limited | Full control ✅ |
| Learning | Abstracts K8s internals | Deep understanding ✅ |
| Portability | Requires migration | Move anywhere ✅ |

**Alternative Cloud Deployment:**
The same Ansible playbooks work with minor modifications:
- **GCP**: Change cloud-controller-manager, use GCE persistent disks
- **Azure**: Use Azure cloud-controller-manager, Azure Disks
- **On-premises**: Remove cloud-specific components, use local storage

### 2.2 Container Registry Setup

```yaml
# ECR repositories to create
repositories:
  - webapp-operator
  - identity-service
  - user-service
  - blog-service
  - frontend
  - gitops-coordinator  # New
  - health-aggregator   # New
```

### 2.3 Namespace Strategy

```yaml
# Production namespace structure
namespaces:
  - name: platform-system      # Operator, coordinator, aggregator
  - name: kafka                # Strimzi/Kafka cluster
  - name: argocd              # Argo CD installation
  - name: default             # Application services (or dedicated namespace)
  - name: monitoring          # Prometheus, Grafana
```

### 2.4 Secrets Management

```yaml
# External Secrets Operator for production
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: database-credentials
  namespace: default
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager
  target:
    name: postgres-credentials
  data:
    - secretKey: password
      remoteRef:
        key: platform/prod/postgres
        property: password
```

### 2.5 Deliverables - Phase 1
- [x] Production Kubernetes cluster running ✅ `make deploy-irsa-platform`
- [ ] ECR repositories created (next step)
- [x] Namespaces created ✅
- [ ] External Secrets Operator installed (optional - can use K8s secrets)
- [x] Ingress controller deployed ✅
- [x] Cert-manager with Let's Encrypt configured ✅

**Remaining for Phase 1:** Only ECR setup needed (covered in next section)

---

## 3. Phase 2: GitOps Foundation

**Duration:** 2-3 weeks  
**Goal:** Establish Git as single source of truth with Argo CD

### 3.1 Create `platform-config` Repository

```
platform-config/
├── README.md
├── base/                           # Immutable base definitions
│   ├── crds/                       # CRD definitions (copied from operator)
│   │   ├── apps.example.com_identityservices.yaml
│   │   ├── apps.example.com_userservices.yaml
│   │   ├── apps.example.com_blogservices.yaml
│   │   ├── apps.example.com_kafkaclusters.yaml
│   │   └── apps.example.com_frontends.yaml
│   ├── operator/
│   │   ├── deployment.yaml
│   │   ├── service-account.yaml
│   │   ├── role.yaml
│   │   └── role-binding.yaml
│   ├── identity-service/
│   │   └── identityservice.yaml    # Base CR template
│   ├── user-service/
│   │   └── userservice.yaml
│   ├── blog-service/
│   │   └── blogservice.yaml
│   ├── frontend/
│   │   └── frontend.yaml
│   └── kafka/
│       └── kafkacluster.yaml
├── overlays/                       # Environment-specific configurations
│   ├── dev/
│   │   ├── kustomization.yaml
│   │   ├── rules.json              # Dev behavior configuration
│   │   └── patches/
│   │       ├── replicas.yaml
│   │       └── resources.yaml
│   ├── staging/
│   │   ├── kustomization.yaml
│   │   ├── rules.json
│   │   └── patches/
│   │       ├── replicas.yaml
│   │       ├── resources.yaml
│   │       └── images.yaml
│   └── prod/
│       ├── kustomization.yaml
│       ├── rules.json              # Production behavior configuration
│       └── patches/
│           ├── replicas-ha.yaml
│           ├── resources-prod.yaml
│           ├── images.yaml
│           └── ecr-images.yaml
├── apps/                           # Argo CD Application definitions
│   ├── operator-app.yaml
│   ├── identity-app.yaml
│   ├── user-app.yaml
│   ├── blog-app.yaml
│   ├── frontend-app.yaml
│   ├── kafka-app.yaml
│   └── app-of-apps.yaml            # Parent application
└── scripts/
    ├── validate.sh                 # Pre-commit validation
    └── bootstrap.sh                # Initial setup script
```

### 3.2 Base CR Templates

```yaml
# base/identity-service/identityservice.yaml
apiVersion: apps.example.com/v1alpha1
kind: IdentityService
metadata:
  name: identity-service
spec:
  serviceName: identity-service
  image: identity-service:latest  # Overridden in overlays
  replicas: 1                     # Overridden in overlays
  port: 3000
  serviceType: ClusterIP
  postgres:
    enabled: true
    database: identity
  redis:
    enabled: true
  kafka:
    enabled: true
    brokers:
      - "my-cluster-kafka-bootstrap.kafka:9092"
```

### 3.3 Overlay Kustomization

```yaml
# overlays/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: default

resources:
  - ../../base/identity-service
  - ../../base/user-service
  - ../../base/blog-service
  - ../../base/frontend

# Image transformations - COORDINATOR WRITES HERE
images:
  - name: identity-service
    newName: 123456789.dkr.ecr.us-east-1.amazonaws.com/identity-service
    newTag: v1.0.0
  - name: user-service
    newName: 123456789.dkr.ecr.us-east-1.amazonaws.com/user-service
    newTag: v1.0.0
  - name: blog-service
    newName: 123456789.dkr.ecr.us-east-1.amazonaws.com/blog-service
    newTag: v1.0.5
  - name: frontend
    newName: 123456789.dkr.ecr.us-east-1.amazonaws.com/frontend
    newTag: v1.0.2

# Strategic merge patches
patchesStrategicMerge:
  - patches/replicas-ha.yaml
  - patches/resources-prod.yaml

# ConfigMap generator for rules
configMapGenerator:
  - name: platform-rules
    files:
      - rules.json
    options:
      disableNameSuffixHash: true
```

### 3.4 Production Rules Configuration

```json
// overlays/prod/rules.json
{
  "version": "1.0.0",
  "environment": "prod",
  "deployment": {
    "identity-service": {
      "syncWave": 0,
      "dependencies": ["postgres", "redis", "kafka"],
      "healthCheck": {
        "endpoint": "/health",
        "timeout": "10s",
        "interval": "30s",
        "failureThreshold": 3
      },
      "rollout": {
        "strategy": "rolling",
        "maxSurge": "25%",
        "maxUnavailable": "25%"
      },
      "rollback": {
        "automatic": true,
        "onHealthFailure": true,
        "historyLimit": 5
      }
    },
    "user-service": {
      "syncWave": 1,
      "dependencies": ["postgres", "kafka", "identity-service"],
      "healthCheck": {
        "endpoint": "/profiles/health",
        "timeout": "10s"
      }
    },
    "blog-service": {
      "syncWave": 1,
      "dependencies": ["postgres", "kafka"],
      "healthCheck": {
        "endpoint": "/api/v1/health",
        "timeout": "10s"
      }
    },
    "frontend": {
      "syncWave": 2,
      "dependencies": ["identity-service", "user-service"],
      "healthCheck": {
        "endpoint": "/",
        "timeout": "5s"
      }
    }
  },
  "scaling": {
    "identity-service": {
      "minReplicas": 2,
      "maxReplicas": 10,
      "targetCPU": 70
    },
    "user-service": {
      "minReplicas": 2,
      "maxReplicas": 8,
      "targetCPU": 70
    }
  },
  "kafka": {
    "topics": {
      "identity.events": { "partitions": 6, "retention": "7d" },
      "user.events": { "partitions": 6, "retention": "7d" },
      "blog.events": { "partitions": 6, "retention": "7d" },
      "cicd.deployment-events": { "partitions": 3, "retention": "30d" },
      "cicd.deployment-status": { "partitions": 3, "retention": "30d" },
      "platform-dlq": { "partitions": 3, "retention": "30d" }
    }
  },
  "eventHandlers": {
    "onDeploymentStart": ["notifySlack", "updateStatus"],
    "onDeploymentSuccess": ["notifySlack", "updateDashboard"],
    "onDeploymentFailure": ["notifyPagerDuty", "triggerRollback", "logToDLQ"]
  }
}
```

### 3.5 Install Argo CD

```bash
# Create namespace
kubectl create namespace argocd

# Install Argo CD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for pods
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Expose via ingress (production)
# Or port-forward for testing:
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

### 3.6 Argo CD Application Definitions

```yaml
# apps/app-of-apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-apps
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/platform-config.git
    targetRevision: main
    path: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

```yaml
# apps/identity-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: identity-service
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/platform-config.git
    targetRevision: main
    path: overlays/prod
    kustomize:
      namePrefix: ""
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: false      # Safety: don't auto-delete
      selfHeal: true    # Auto-sync drift
    syncOptions:
      - CreateNamespace=true
      - PruneLast=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

### 3.7 Migrate Operator to Git

```yaml
# apps/operator-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: webapp-operator
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"  # Deploy operator first
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/platform-config.git
    targetRevision: main
    path: base/operator
  destination:
    server: https://kubernetes.default.svc
    namespace: platform-system
  syncPolicy:
    automated:
      selfHeal: true
```

### 3.8 Deliverables - Phase 2
- [ ] `platform-config` repository created and structured
- [ ] Base CRs migrated from operator samples
- [ ] Overlay configurations for dev/staging/prod
- [ ] `rules.json` created for each environment
- [ ] Argo CD installed and configured
- [ ] App-of-apps pattern implemented
- [ ] All services syncing via Argo CD
- [ ] Operator deployed via Argo CD
- [ ] Git branch protection enabled
- [ ] CODEOWNERS file configured

---

## 4. Phase 3: Orchestration Layer

**Duration:** 3-4 weeks  
**Goal:** Implement GitOps Coordinator and event-driven deployment orchestration

### 4.1 CI/CD Kafka Topics

```yaml
# Add to KafkaCluster CR or create separately
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: cicd-deployment-events
  namespace: kafka
  labels:
    strimzi.io/cluster: my-cluster
spec:
  partitions: 6
  replicas: 1  # Increase for production
  config:
    retention.ms: "2592000000"  # 30 days
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: cicd-deployment-status
  namespace: kafka
  labels:
    strimzi.io/cluster: my-cluster
spec:
  partitions: 6
  replicas: 1
  config:
    retention.ms: "2592000000"
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: cicd-health-events
  namespace: kafka
  labels:
    strimzi.io/cluster: my-cluster
spec:
  partitions: 3
  replicas: 1
  config:
    retention.ms: "604800000"  # 7 days
```

### 4.2 GitOps Coordinator Service

Create new service: `microservices-platform/services/gitops-coordinator/`

```
gitops-coordinator/
├── Dockerfile
├── requirements.txt
├── src/
│   ├── __init__.py
│   ├── main.py
│   ├── config.py
│   ├── coordinator/
│   │   ├── __init__.py
│   │   ├── git_writer.py
│   │   ├── kustomize_updater.py
│   │   └── argocd_client.py
│   ├── kafka/
│   │   ├── __init__.py
│   │   ├── consumer.py
│   │   ├── producer.py
│   │   └── events.py
│   ├── orchestration/
│   │   ├── __init__.py
│   │   ├── dependency_graph.py
│   │   ├── update_queue.py
│   │   └── wave_processor.py
│   └── health/
│       ├── __init__.py
│       └── aggregator.py
└── tests/
```

#### Core Coordinator Implementation

```python
# src/coordinator/git_writer.py
"""
GitOps Coordinator - Single Writer to platform-config repository
"""

import os
import yaml
import json
import asyncio
from datetime import datetime
from git import Repo
from pathlib import Path
from typing import Dict, Any, Optional
import logging

logger = logging.getLogger(__name__)

class GitWriter:
    """
    Single writer to the platform-config repository.
    Implements the Git modification contract.
    """
    
    def __init__(self, repo_url: str, local_path: str, branch: str = "main"):
        self.repo_url = repo_url
        self.local_path = Path(local_path)
        self.branch = branch
        self.repo: Optional[Repo] = None
        self._lock = asyncio.Lock()
    
    async def initialize(self):
        """Clone or pull the repository"""
        async with self._lock:
            if self.local_path.exists():
                self.repo = Repo(self.local_path)
                self.repo.remotes.origin.pull()
                logger.info(f"Pulled latest from {self.repo_url}")
            else:
                self.repo = Repo.clone_from(self.repo_url, self.local_path)
                logger.info(f"Cloned {self.repo_url} to {self.local_path}")
    
    async def update_image_tag(
        self, 
        environment: str, 
        service: str, 
        new_tag: str,
        commit_message: str
    ) -> str:
        """
        Update the image tag in kustomization.yaml
        Returns the commit SHA
        """
        async with self._lock:
            # Pull latest
            self.repo.remotes.origin.pull()
            
            kustomization_path = self.local_path / "overlays" / environment / "kustomization.yaml"
            
            with open(kustomization_path, 'r') as f:
                kustomization = yaml.safe_load(f)
            
            # Find and update the image
            images = kustomization.get('images', [])
            updated = False
            for img in images:
                if img.get('name') == service:
                    old_tag = img.get('newTag', 'unknown')
                    img['newTag'] = new_tag
                    updated = True
                    logger.info(f"Updated {service}: {old_tag} -> {new_tag}")
                    break
            
            if not updated:
                raise ValueError(f"Service {service} not found in kustomization")
            
            # Write back
            with open(kustomization_path, 'w') as f:
                yaml.dump(kustomization, f, default_flow_style=False)
            
            # Commit and push
            self.repo.index.add([str(kustomization_path)])
            commit = self.repo.index.commit(commit_message)
            self.repo.remotes.origin.push()
            
            logger.info(f"Committed and pushed: {commit.hexsha[:8]}")
            return commit.hexsha
    
    async def update_replicas(
        self,
        environment: str,
        service: str,
        replicas: int,
        commit_message: str
    ) -> str:
        """Update replica count in patch file"""
        async with self._lock:
            self.repo.remotes.origin.pull()
            
            patch_path = self.local_path / "overlays" / environment / "patches" / f"{service}-patch.yaml"
            
            if patch_path.exists():
                with open(patch_path, 'r') as f:
                    patch = yaml.safe_load(f)
            else:
                patch = {
                    'apiVersion': 'apps.example.com/v1alpha1',
                    'kind': service.replace('-', '').title(),
                    'metadata': {'name': service},
                    'spec': {}
                }
            
            patch['spec']['replicas'] = replicas
            
            with open(patch_path, 'w') as f:
                yaml.dump(patch, f, default_flow_style=False)
            
            self.repo.index.add([str(patch_path)])
            commit = self.repo.index.commit(commit_message)
            self.repo.remotes.origin.push()
            
            return commit.hexsha
    
    async def update_rules(
        self,
        environment: str,
        updates: Dict[str, Any],
        commit_message: str
    ) -> str:
        """Update rules.json configuration"""
        async with self._lock:
            self.repo.remotes.origin.pull()
            
            rules_path = self.local_path / "overlays" / environment / "rules.json"
            
            with open(rules_path, 'r') as f:
                rules = json.load(f)
            
            # Deep merge updates
            self._deep_merge(rules, updates)
            
            with open(rules_path, 'w') as f:
                json.dump(rules, f, indent=2)
            
            self.repo.index.add([str(rules_path)])
            commit = self.repo.index.commit(commit_message)
            self.repo.remotes.origin.push()
            
            return commit.hexsha
    
    def _deep_merge(self, base: dict, updates: dict):
        """Recursively merge updates into base"""
        for key, value in updates.items():
            if key in base and isinstance(base[key], dict) and isinstance(value, dict):
                self._deep_merge(base[key], value)
            else:
                base[key] = value
```

```python
# src/orchestration/wave_processor.py
"""
Dependency-aware deployment orchestrator using sync waves
"""

import asyncio
from dataclasses import dataclass
from typing import List, Dict, Set
from enum import Enum
import logging

logger = logging.getLogger(__name__)

class DeploymentStatus(Enum):
    PENDING = "pending"
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    FAILED = "failed"
    ROLLED_BACK = "rolled_back"

@dataclass
class DeploymentRequest:
    service: str
    image: str
    environment: str
    sync_wave: int
    dependencies: List[str]
    correlation_id: str
    status: DeploymentStatus = DeploymentStatus.PENDING

class WaveProcessor:
    """
    Processes deployments in sync waves, respecting dependencies
    """
    
    def __init__(self, git_writer, argocd_client, health_checker, kafka_producer):
        self.git_writer = git_writer
        self.argocd = argocd_client
        self.health = health_checker
        self.kafka = kafka_producer
        self.pending_queue: Dict[str, DeploymentRequest] = {}
    
    async def queue_deployment(self, request: DeploymentRequest):
        """Add deployment to queue"""
        self.pending_queue[request.service] = request
        await self.kafka.publish_status(
            request.correlation_id,
            request.service,
            "QUEUED",
            f"Deployment queued in wave {request.sync_wave}"
        )
        logger.info(f"Queued {request.service} for deployment in wave {request.sync_wave}")
    
    async def process_waves(self, environment: str):
        """Process all queued deployments by sync wave"""
        if not self.pending_queue:
            return
        
        # Group by sync wave
        waves: Dict[int, List[DeploymentRequest]] = {}
        for request in self.pending_queue.values():
            wave = request.sync_wave
            if wave not in waves:
                waves[wave] = []
            waves[wave].append(request)
        
        # Process in order
        for wave_num in sorted(waves.keys()):
            logger.info(f"Processing sync wave {wave_num}")
            wave_requests = waves[wave_num]
            
            # Check dependencies for all in this wave
            ready_requests = []
            for req in wave_requests:
                if await self._check_dependencies(req):
                    ready_requests.append(req)
                else:
                    logger.warning(f"Dependencies not ready for {req.service}")
                    await self.kafka.publish_status(
                        req.correlation_id,
                        req.service,
                        "WAITING",
                        "Waiting for dependencies"
                    )
            
            # Deploy all ready services in parallel
            if ready_requests:
                await asyncio.gather(*[
                    self._deploy_service(req, environment)
                    for req in ready_requests
                ])
            
            # Wait for wave to complete before next wave
            await self._wait_for_wave_completion(ready_requests, environment)
    
    async def _check_dependencies(self, request: DeploymentRequest) -> bool:
        """Check if all dependencies are healthy"""
        for dep in request.dependencies:
            if dep in self.pending_queue:
                # Dependency is also being deployed
                dep_req = self.pending_queue[dep]
                if dep_req.status != DeploymentStatus.COMPLETED:
                    return False
            else:
                # Check if existing service is healthy
                health = await self.health.check_service(dep)
                if not health.is_healthy:
                    return False
        return True
    
    async def _deploy_service(self, request: DeploymentRequest, environment: str):
        """Deploy a single service"""
        try:
            request.status = DeploymentStatus.IN_PROGRESS
            
            await self.kafka.publish_status(
                request.correlation_id,
                request.service,
                "DEPLOYING",
                f"Updating {request.service} to {request.image}"
            )
            
            # Update Git
            commit_sha = await self.git_writer.update_image_tag(
                environment=environment,
                service=request.service,
                new_tag=request.image.split(':')[-1],
                commit_message=f"deploy({request.service}): Update to {request.image}\n\nCorrelation-ID: {request.correlation_id}"
            )
            
            # Trigger Argo CD sync
            await self.argocd.sync_application(f"{request.service}")
            
            logger.info(f"Deployed {request.service} via commit {commit_sha[:8]}")
            
        except Exception as e:
            request.status = DeploymentStatus.FAILED
            await self.kafka.publish_status(
                request.correlation_id,
                request.service,
                "FAILED",
                str(e)
            )
            raise
    
    async def _wait_for_wave_completion(self, requests: List[DeploymentRequest], environment: str):
        """Wait for all services in wave to be healthy"""
        max_wait = 300  # 5 minutes
        interval = 10
        elapsed = 0
        
        while elapsed < max_wait:
            all_healthy = True
            for req in requests:
                # Check Argo CD sync status
                sync_status = await self.argocd.get_sync_status(req.service)
                if sync_status != "Synced":
                    all_healthy = False
                    continue
                
                # Check service health
                health = await self.health.check_service(req.service)
                if not health.is_healthy:
                    all_healthy = False
                    continue
                
                req.status = DeploymentStatus.COMPLETED
                await self.kafka.publish_status(
                    req.correlation_id,
                    req.service,
                    "COMPLETED",
                    "Deployment successful"
                )
            
            if all_healthy:
                logger.info(f"Wave completed successfully")
                return
            
            await asyncio.sleep(interval)
            elapsed += interval
        
        # Timeout - mark remaining as failed
        for req in requests:
            if req.status != DeploymentStatus.COMPLETED:
                req.status = DeploymentStatus.FAILED
                await self.kafka.publish_status(
                    req.correlation_id,
                    req.service,
                    "TIMEOUT",
                    "Deployment timed out waiting for health check"
                )
```

```python
# src/kafka/consumer.py
"""
Kafka consumer for deployment events
"""

import asyncio
import json
from aiokafka import AIOKafkaConsumer
from typing import Callable, Dict
import logging

logger = logging.getLogger(__name__)

class DeploymentEventConsumer:
    def __init__(
        self,
        brokers: str,
        topic: str = "cicd-deployment-events",
        group_id: str = "gitops-coordinator"
    ):
        self.brokers = brokers
        self.topic = topic
        self.group_id = group_id
        self.consumer = None
        self.handlers: Dict[str, Callable] = {}
    
    def register_handler(self, event_type: str, handler: Callable):
        self.handlers[event_type] = handler
    
    async def start(self):
        self.consumer = AIOKafkaConsumer(
            self.topic,
            bootstrap_servers=self.brokers,
            group_id=self.group_id,
            value_deserializer=lambda m: json.loads(m.decode('utf-8')),
            auto_offset_reset='latest'
        )
        await self.consumer.start()
        logger.info(f"Started consuming from {self.topic}")
        
        try:
            async for msg in self.consumer:
                await self._process_message(msg)
        finally:
            await self.consumer.stop()
    
    async def _process_message(self, msg):
        try:
            event = msg.value
            event_type = event.get('eventType')
            
            logger.info(f"Received {event_type}: {event.get('service', {}).get('name')}")
            
            handler = self.handlers.get(event_type)
            if handler:
                await handler(event)
            else:
                logger.warning(f"No handler for event type: {event_type}")
                
        except Exception as e:
            logger.error(f"Error processing message: {e}")
            # TODO: Send to DLQ
```

```python
# src/main.py
"""
GitOps Coordinator - Main Entry Point
"""

import asyncio
import os
import logging
from fastapi import FastAPI, BackgroundTasks
from contextlib import asynccontextmanager

from coordinator.git_writer import GitWriter
from coordinator.argocd_client import ArgoCDClient
from orchestration.wave_processor import WaveProcessor, DeploymentRequest
from kafka.consumer import DeploymentEventConsumer
from kafka.producer import DeploymentStatusProducer
from health.aggregator import HealthAggregator

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration from environment
CONFIG = {
    'GIT_REPO_URL': os.getenv('GIT_REPO_URL', 'https://github.com/your-org/platform-config.git'),
    'GIT_LOCAL_PATH': os.getenv('GIT_LOCAL_PATH', '/tmp/platform-config'),
    'KAFKA_BROKERS': os.getenv('KAFKA_BROKERS', 'my-cluster-kafka-bootstrap.kafka:9092'),
    'ARGOCD_SERVER': os.getenv('ARGOCD_SERVER', 'argocd-server.argocd:443'),
    'ENVIRONMENT': os.getenv('ENVIRONMENT', 'prod'),
}

# Global instances
git_writer: GitWriter = None
wave_processor: WaveProcessor = None
kafka_consumer: DeploymentEventConsumer = None
kafka_producer: DeploymentStatusProducer = None
health_aggregator: HealthAggregator = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global git_writer, wave_processor, kafka_consumer, kafka_producer, health_aggregator
    
    # Initialize components
    git_writer = GitWriter(
        repo_url=CONFIG['GIT_REPO_URL'],
        local_path=CONFIG['GIT_LOCAL_PATH']
    )
    await git_writer.initialize()
    
    kafka_producer = DeploymentStatusProducer(CONFIG['KAFKA_BROKERS'])
    await kafka_producer.start()
    
    argocd = ArgoCDClient(CONFIG['ARGOCD_SERVER'])
    health_aggregator = HealthAggregator()
    
    wave_processor = WaveProcessor(
        git_writer=git_writer,
        argocd_client=argocd,
        health_checker=health_aggregator,
        kafka_producer=kafka_producer
    )
    
    # Start Kafka consumer in background
    kafka_consumer = DeploymentEventConsumer(CONFIG['KAFKA_BROKERS'])
    kafka_consumer.register_handler('DEPLOYMENT_REQUESTED', handle_deployment_request)
    asyncio.create_task(kafka_consumer.start())
    
    logger.info("GitOps Coordinator started")
    
    yield
    
    # Cleanup
    if kafka_producer:
        await kafka_producer.stop()
    logger.info("GitOps Coordinator stopped")

app = FastAPI(title="GitOps Coordinator", lifespan=lifespan)

async def handle_deployment_request(event: dict):
    """Handle incoming deployment request from CI/CD"""
    service = event['service']
    
    # Load rules to get sync wave and dependencies
    rules = await load_rules(CONFIG['ENVIRONMENT'])
    service_rules = rules['deployment'].get(service['name'], {})
    
    request = DeploymentRequest(
        service=service['name'],
        image=service['image'],
        environment=CONFIG['ENVIRONMENT'],
        sync_wave=service_rules.get('syncWave', 0),
        dependencies=service_rules.get('dependencies', []),
        correlation_id=event['correlationId']
    )
    
    await wave_processor.queue_deployment(request)
    
    # Process immediately (or batch based on configuration)
    await wave_processor.process_waves(CONFIG['ENVIRONMENT'])

async def load_rules(environment: str) -> dict:
    """Load rules.json from Git"""
    rules_path = f"{CONFIG['GIT_LOCAL_PATH']}/overlays/{environment}/rules.json"
    import json
    with open(rules_path) as f:
        return json.load(f)

@app.get("/health")
async def health_check():
    return {"status": "healthy", "environment": CONFIG['ENVIRONMENT']}

@app.get("/status")
async def get_status():
    return {
        "pending_deployments": len(wave_processor.pending_queue) if wave_processor else 0,
        "environment": CONFIG['ENVIRONMENT']
    }

@app.post("/deploy")
async def trigger_deployment(service: str, image: str, background_tasks: BackgroundTasks):
    """Manual deployment trigger (for testing)"""
    event = {
        'eventType': 'DEPLOYMENT_REQUESTED',
        'correlationId': f"manual-{service}-{image.split(':')[-1]}",
        'service': {
            'name': service,
            'image': image
        }
    }
    background_tasks.add_task(handle_deployment_request, event)
    return {"status": "queued", "correlation_id": event['correlationId']}
```

### 4.3 CI Pipeline Integration

Update your CI pipelines to publish to Kafka instead of direct deployment:

```yaml
# .github/workflows/deploy.yml (or GitLab CI equivalent)
name: Build and Deploy

on:
  push:
    branches: [main]
    paths:
      - 'services/identity-service/**'

jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      image_tag: ${{ steps.build.outputs.tag }}
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Build and Push Image
        id: build
        run: |
          TAG=v${{ github.run_number }}
          docker build -t $ECR_REGISTRY/identity-service:$TAG ./services/identity-service
          docker push $ECR_REGISTRY/identity-service:$TAG
          echo "tag=$TAG" >> $GITHUB_OUTPUT

  deploy:
    needs: build
    runs-on: ubuntu-latest
    
    steps:
      - name: Publish Deployment Event to Kafka
        run: |
          # Use kafkacat or a simple producer script
          echo '{
            "eventId": "${{ github.run_id }}",
            "correlationId": "gh-${{ github.run_id }}",
            "eventType": "DEPLOYMENT_REQUESTED",
            "timestamp": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
            "service": {
              "name": "identity-service",
              "version": "${{ needs.build.outputs.image_tag }}",
              "image": "${{ env.ECR_REGISTRY }}/identity-service:${{ needs.build.outputs.image_tag }}"
            },
            "environment": "prod",
            "metadata": {
              "gitCommit": "${{ github.sha }}",
              "gitBranch": "${{ github.ref_name }}",
              "pipelineId": "${{ github.run_id }}",
              "triggeredBy": "${{ github.actor }}"
            }
          }' | kafkacat -P -b $KAFKA_BROKERS -t cicd-deployment-events
```

### 4.4 Coordinator Kubernetes Deployment

```yaml
# base/coordinator/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitops-coordinator
  namespace: platform-system
spec:
  replicas: 1  # SINGLETON - must be 1
  strategy:
    type: Recreate  # No rolling updates for singleton
  selector:
    matchLabels:
      app: gitops-coordinator
  template:
    metadata:
      labels:
        app: gitops-coordinator
    spec:
      serviceAccountName: gitops-coordinator
      containers:
        - name: coordinator
          image: gitops-coordinator:v1.0.0
          ports:
            - containerPort: 8000
          env:
            - name: GIT_REPO_URL
              valueFrom:
                secretKeyRef:
                  name: git-credentials
                  key: repo_url
            - name: KAFKA_BROKERS
              value: "my-cluster-kafka-bootstrap.kafka:9092"
            - name: ARGOCD_SERVER
              value: "argocd-server.argocd:443"
            - name: ENVIRONMENT
              value: "prod"
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: gitops-coordinator
  namespace: platform-system
spec:
  selector:
    app: gitops-coordinator
  ports:
    - port: 8000
      targetPort: 8000
```

### 4.5 Deliverables - Phase 3
- [ ] CI/CD Kafka topics created
- [ ] GitOps Coordinator service implemented
- [ ] Wave processor with dependency graph
- [ ] Kafka consumer for deployment events
- [ ] Kafka producer for status events
- [ ] CI pipelines updated to publish to Kafka
- [ ] Coordinator deployed as singleton
- [ ] Health aggregator service (basic)
- [ ] Integration tests passing

---

## 5. Phase 4: Advanced Operations

**Duration:** 2-3 weeks  
**Goal:** Production hardening and observability

### 5.1 Health Check Aggregator

```python
# services/health-aggregator/src/aggregator.py
"""
Centralized health check aggregator service
"""

import asyncio
import aiohttp
from dataclasses import dataclass
from typing import Dict, List
from enum import Enum
from datetime import datetime
import logging

logger = logging.getLogger(__name__)

class HealthStatus(Enum):
    HEALTHY = "healthy"
    DEGRADED = "degraded"
    UNHEALTHY = "unhealthy"
    UNKNOWN = "unknown"

@dataclass
class ServiceHealth:
    name: str
    status: HealthStatus
    endpoint: str
    last_check: datetime
    response_time_ms: float
    message: str = ""

class HealthAggregator:
    def __init__(self, rules: dict):
        self.rules = rules
        self.service_states: Dict[str, ServiceHealth] = {}
        self._lock = asyncio.Lock()
    
    async def check_all_services(self) -> Dict[str, ServiceHealth]:
        """Check health of all configured services"""
        tasks = []
        for service, config in self.rules.get('deployment', {}).items():
            endpoint = config.get('healthCheck', {}).get('endpoint', '/health')
            timeout = self._parse_duration(config.get('healthCheck', {}).get('timeout', '5s'))
            tasks.append(self._check_service(service, endpoint, timeout))
        
        results = await asyncio.gather(*tasks, return_exceptions=True)
        
        async with self._lock:
            for result in results:
                if isinstance(result, ServiceHealth):
                    self.service_states[result.name] = result
        
        return self.service_states
    
    async def _check_service(self, name: str, endpoint: str, timeout: float) -> ServiceHealth:
        """Check a single service's health"""
        url = f"http://{name}:3000{endpoint}"
        start = datetime.now()
        
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(url, timeout=aiohttp.ClientTimeout(total=timeout)) as resp:
                    elapsed = (datetime.now() - start).total_seconds() * 1000
                    
                    if resp.status == 200:
                        return ServiceHealth(
                            name=name,
                            status=HealthStatus.HEALTHY,
                            endpoint=endpoint,
                            last_check=datetime.now(),
                            response_time_ms=elapsed
                        )
                    else:
                        return ServiceHealth(
                            name=name,
                            status=HealthStatus.DEGRADED,
                            endpoint=endpoint,
                            last_check=datetime.now(),
                            response_time_ms=elapsed,
                            message=f"HTTP {resp.status}"
                        )
        except asyncio.TimeoutError:
            return ServiceHealth(
                name=name,
                status=HealthStatus.UNHEALTHY,
                endpoint=endpoint,
                last_check=datetime.now(),
                response_time_ms=timeout * 1000,
                message="Timeout"
            )
        except Exception as e:
            return ServiceHealth(
                name=name,
                status=HealthStatus.UNHEALTHY,
                endpoint=endpoint,
                last_check=datetime.now(),
                response_time_ms=0,
                message=str(e)
            )
    
    def get_system_health(self) -> HealthStatus:
        """Calculate overall system health"""
        if not self.service_states:
            return HealthStatus.UNKNOWN
        
        statuses = [s.status for s in self.service_states.values()]
        
        if any(s == HealthStatus.UNHEALTHY for s in statuses):
            return HealthStatus.UNHEALTHY
        elif any(s == HealthStatus.DEGRADED for s in statuses):
            return HealthStatus.DEGRADED
        elif all(s == HealthStatus.HEALTHY for s in statuses):
            return HealthStatus.HEALTHY
        return HealthStatus.UNKNOWN
    
    def _parse_duration(self, duration: str) -> float:
        """Parse duration string like '5s' or '100ms'"""
        if duration.endswith('ms'):
            return float(duration[:-2]) / 1000
        elif duration.endswith('s'):
            return float(duration[:-1])
        return 5.0  # default
```

### 5.2 Operator Hot-Reload Enhancement

Update your operator roles to watch ConfigMaps:

```yaml
# roles/identityservice/tasks/main.yml - Add ConfigMap watching
- name: Watch for runtime config changes
  kubernetes.core.k8s_info:
    api_version: v1
    kind: ConfigMap
    name: platform-rules
    namespace: "{{ ansible_operator_meta.namespace }}"
  register: platform_rules

- name: Load runtime rules
  set_fact:
    runtime_rules: "{{ platform_rules.resources[0].data['rules.json'] | from_json }}"
  when: platform_rules.resources | length > 0

- name: Apply service-specific rules
  set_fact:
    service_rules: "{{ runtime_rules.deployment['identity-service'] | default({}) }}"
  when: runtime_rules is defined
```

### 5.3 Monitoring and Dashboards

```yaml
# monitoring/prometheus-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gitops-alerts
  namespace: monitoring
spec:
  groups:
    - name: gitops
      rules:
        - alert: DeploymentFailed
          expr: |
            sum(increase(gitops_deployment_failures_total[5m])) > 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "Deployment failed"
            description: "A deployment has failed in the last 5 minutes"
        
        - alert: CoordinatorDown
          expr: |
            absent(up{job="gitops-coordinator"} == 1)
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "GitOps Coordinator is down"
        
        - alert: ArgoCDOutOfSync
          expr: |
            sum(argocd_app_info{sync_status!="Synced"}) > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Argo CD applications out of sync"
```

### 5.4 DLQ Processing

Enhance the existing `platform-dlq` topic handling:

```python
# services/gitops-coordinator/src/dlq/processor.py
"""
Dead Letter Queue processor for failed deployment events
"""

class DLQProcessor:
    def __init__(self, kafka_consumer, kafka_producer, max_retries: int = 3):
        self.consumer = kafka_consumer
        self.producer = kafka_producer
        self.max_retries = max_retries
    
    async def process_dlq(self):
        """Process messages from DLQ with exponential backoff"""
        async for msg in self.consumer:
            event = msg.value
            retry_count = event.get('_retryCount', 0)
            
            if retry_count >= self.max_retries:
                logger.error(f"Max retries exceeded for {event['correlationId']}")
                await self._send_to_permanent_failure(event)
                continue
            
            # Exponential backoff
            wait_time = 2 ** retry_count * 60  # 1min, 2min, 4min
            await asyncio.sleep(wait_time)
            
            # Republish with incremented retry count
            event['_retryCount'] = retry_count + 1
            await self.producer.publish('cicd-deployment-events', event)
```

### 5.5 Deliverables - Phase 4
- [ ] Health aggregator fully implemented
- [ ] Prometheus metrics and alerts
- [ ] Grafana dashboards for GitOps
- [ ] DLQ processing with retries
- [ ] Operator hot-reload from ConfigMaps
- [ ] Runbooks for common issues
- [ ] Load testing completed
- [ ] Security audit passed

---

## 6. Implementation Timeline

```
Week 1-2:   Phase 1 - Production Infrastructure ✅ COMPLETE
            - Cluster setup (kubeadm) ✅ make deploy-irsa-platform
            - ECR setup (remaining task)
            - Ingress, cert-manager ✅
            
Week 3-4:   Phase 2 - GitOps Foundation (Part 1)
            - platform-config repository
            - Base CRs and overlays
            - Argo CD installation
            
Week 5:     Phase 2 - GitOps Foundation (Part 2)
            - App-of-apps pattern
            - Migrate all services to Argo CD
            - rules.json configuration
            
Week 6-7:   Phase 3 - Orchestration Layer (Part 1)
            - GitOps Coordinator service
            - Kafka CI/CD topics
            - Wave processor
            
Week 8-9:   Phase 3 - Orchestration Layer (Part 2)
            - CI pipeline integration
            - Status publishing
            - Integration testing
            
Week 10-11: Phase 4 - Advanced Operations
            - Health aggregator
            - Monitoring and dashboards
            - DLQ processing
            
Week 12:    Go-Live
            - Production deployment
            - Documentation
            - Team training
```

---

## 7. Risk Mitigation

### 7.1 Rollback Strategy
- Git revert capability at every stage
- Argo CD manual sync available
- Previous image tags preserved
- Database migrations with rollback scripts

### 7.2 Single Point of Failure - Coordinator
- Health checks with automatic restart
- PodDisruptionBudget prevents accidental deletion
- Leader election if scaling needed later
- Manual API available for emergency deployments

### 7.3 Kafka Availability
- Multi-replica Kafka cluster for production
- DLQ prevents message loss
- Circuit breaker in coordinator for Kafka failures

### 7.4 Git Repository Issues
- Local cache in coordinator
- Retry logic for Git operations
- Fallback to manual Argo CD sync

---

## 8. Zero-Redeploy Configuration Pattern

### 8.1 Core Philosophy

**"Configuration as Common Language"** - The same paths that humans use to change behavior are the same paths that CI/CD uses, which are the same paths that AI agents use.

**The Goal:** Change application behavior WITHOUT:
- Restarting pods
- Rebuilding images  
- Redeploying operators
- Manual intervention

### 8.2 Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        GitOps Coordinator                                │
│                    (writes to platform-config)                          │
└─────────────────────────────────────┬───────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     platform-config Repository                          │
│  ┌─────────────────────┐  ┌─────────────────────┐  ┌──────────────────┐ │
│  │   base/             │  │   overlays/dev/     │  │   overlays/prod/ │ │
│  │   - CRD templates   │  │   - rules.json      │  │   - rules.json   │ │
│  │   - Default values  │  │   - kustomization   │  │   - kustomization│ │
│  └─────────────────────┘  └─────────────────────┘  └──────────────────┘ │
└─────────────────────────────────────┬───────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          ArgoCD Sync                                     │
│              (detects changes, applies to cluster)                       │
└─────────────────────────────────────┬───────────────────────────────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    ▼                 ▼                 ▼
          ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
          │  ConfigMap      │ │  ConfigMap      │ │  ConfigMap      │
          │  (rules.json)   │ │  (identity-cfg) │ │  (blog-cfg)     │
          └────────┬────────┘ └────────┬────────┘ └────────┬────────┘
                   │                   │                   │
                   ▼                   ▼                   ▼
          ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
          │  Operator       │ │  Identity       │ │  Blog           │
          │  (watches CM)   │ │  Service        │ │  Service        │
          │  hot-reloads    │ │  (hot-reload)   │ │  (hot-reload)   │
          └─────────────────┘ └─────────────────┘ └─────────────────┘
```

### 8.3 Layered Configuration Strategy

#### Layer 1: Base Templates (Static)
```yaml
# base/identity-service/identity-service.yaml
apiVersion: healthxcape.io/v1alpha1
kind: IdentityService
metadata:
  name: identity-service
spec:
  replicas: 1  # Default, overridden by overlay
  image: identity-service:IMAGE_TAG  # Placeholder
  config:
    jwtExpiry: "1h"    # Default
    rateLimitRps: 100  # Default
```

#### Layer 2: Overlay Rules (Dynamic)
```yaml
# overlays/dev/rules.json
{
  "environment": "dev",
  "services": {
    "identity-service": {
      "replicas": 1,
      "imageTag": "v1.2.3",
      "config": {
        "jwtExpiry": "24h",
        "rateLimitRps": 1000,
        "debugMode": true
      }
    },
    "blog-service": {
      "replicas": 2,
      "imageTag": "v2.0.0"
    }
  },
  "featureFlags": {
    "enableNewAuthFlow": true,
    "enableCaching": true
  }
}
```

#### Layer 3: Kustomize Integration
```yaml
# overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

# Generate ConfigMap from rules.json (content-addressable hash)
configMapGenerator:
  - name: platform-rules
    files:
      - rules.json

# Replace placeholders in CRDs with values from generated ConfigMap
replacements:
  - source:
      kind: ConfigMap
      name: platform-rules
      fieldPath: data.rules\.json
    targets:
      - select:
          kind: IdentityService
        fieldPaths:
          - spec.image
        options:
          delimiter: ':'
          index: 1
```

### 8.4 Operator Hot-Reload Pattern

**Key Insight:** Operators are generic and NEVER need redeployment. All behavior is driven by ConfigMaps.

```python
# Pseudo-code for hot-reload capable operator
class GenericOperator:
    def __init__(self):
        self.config = {}
        self.watch_configmap()
    
    def watch_configmap(self):
        """Watch for ConfigMap changes and hot-reload"""
        # Kubernetes informer pattern
        self.informer.add_event_handler(
            add_func=self.on_config_change,
            update_func=self.on_config_change,
            delete_func=self.on_config_delete
        )
    
    def on_config_change(self, configmap):
        """Called when ConfigMap is updated - NO RESTART NEEDED"""
        new_config = json.loads(configmap.data['rules.json'])
        self.config = new_config
        self.apply_config_changes()
        logger.info(f"Config hot-reloaded: {new_config}")
    
    def apply_config_changes(self):
        """Apply new configuration without restart"""
        # Update in-memory caches
        # Adjust rate limiters
        # Toggle feature flags
        # All without pod restart!
```

### 8.5 GitOps Coordinator Integration

**The Coordinator writes ONE file, everything propagates:**

```python
class GitOpsCoordinator:
    async def update_service_config(self, environment: str, service: str, changes: dict):
        """Update a single file, let Kustomize + ArgoCD propagate"""
        
        # 1. Read current rules.json
        rules_path = f"overlays/{environment}/rules.json"
        current = json.loads(await self.git.read_file(rules_path))
        
        # 2. Apply changes
        current['services'][service].update(changes)
        
        # 3. Write back
        await self.git.write_file(rules_path, json.dumps(current, indent=2))
        await self.git.commit_and_push(f"Update {service} config in {environment}")
        
        # 4. ArgoCD detects change, syncs, ConfigMap updates
        # 5. Operator hot-reloads from ConfigMap
        # 6. Behavior changes - NO POD RESTART!
```

### 8.6 Rule Engine Configuration

The `rules.json` supports advanced rule evaluation:

#### JSONLogic Rules
```json
{
  "rules": {
    "autoScale": {
      "condition": {
        "and": [
          {">": [{"var": "cpu_percent"}, 80]},
          {"<": [{"var": "replicas"}, 10]}
        ]
      },
      "action": "scale_up"
    },
    "circuitBreaker": {
      "condition": {
        ">": [{"var": "error_rate"}, 0.5]
      },
      "action": "trip_breaker"
    }
  }
}
```

#### CEL Expressions (Common Expression Language)
```json
{
  "rules": {
    "deploymentGate": {
      "expression": "request.time.getHours() >= 9 && request.time.getHours() <= 17",
      "description": "Only deploy during business hours"
    }
  }
}
```

### 8.7 MCP Integration (AI Agent Interface)

**The same paths humans and CI/CD use are exposed to AI agents:**

```python
class PlatformMCPServer:
    """Model Context Protocol server for AI agent integration"""
    
    @mcp.tool()
    async def update_feature_flag(self, flag: str, value: bool, environment: str):
        """AI agent can toggle feature flags via the same GitOps path"""
        return await self.coordinator.update_config(
            environment=environment,
            path=f"featureFlags.{flag}",
            value=value
        )
    
    @mcp.tool()
    async def scale_service(self, service: str, replicas: int, environment: str):
        """AI agent can scale services via the same GitOps path"""
        return await self.coordinator.update_config(
            environment=environment,
            path=f"services.{service}.replicas",
            value=replicas
        )
    
    @mcp.tool()
    async def get_service_health(self, service: str, environment: str):
        """AI agent can query health via the same monitoring path"""
        return await self.health_aggregator.get_status(service, environment)
```

**Why This Matters:**
- Humans edit `rules.json` in Git → behavior changes
- CI/CD calls Coordinator API → updates `rules.json` → behavior changes  
- AI agents call MCP tools → Coordinator updates `rules.json` → behavior changes
- **Same path, same audit trail, same GitOps guarantees**

### 8.8 Benefits Summary

| Aspect | Traditional Approach | Zero-Redeploy Pattern |
|--------|---------------------|----------------------|
| **Config Change** | Rebuild image, redeploy | Update ConfigMap, hot-reload |
| **Feature Flags** | Code change, PR, deploy | Edit rules.json, auto-sync |
| **Scaling** | kubectl scale / HPA | Update rules.json, operator applies |
| **Rollback** | Redeploy previous image | Git revert rules.json |
| **Audit Trail** | Container registry + logs | Git history (complete) |
| **AI Integration** | Custom APIs | Same MCP tools as humans |

### 8.9 Implementation Checklist

- [ ] Add `rules.json` to each overlay (dev, staging, prod)
- [ ] Update kustomization.yaml with configMapGenerator + replacements
- [ ] Modify operators to watch ConfigMaps and hot-reload
- [ ] Add rule evaluation engine (JSONLogic/CEL) to operators
- [ ] Implement MCP server in GitOps Coordinator
- [ ] Create Ansible role for operator ConfigMap watching
- [ ] Test end-to-end: Git commit → ArgoCD sync → ConfigMap update → Hot-reload

---

## 9. Self-Governing Architecture (Spec-Kits)

### 9.1 Overview

**Constitutional AI for Infrastructure** - MCP agents that physically cannot violate platform invariants.

As AI agents gain the ability to manage infrastructure, we need governance mechanisms that go beyond "trust the agent." Spec-Kits provide a hierarchical constraint system that validates every agent action before execution.

```
┌─────────────────────────────────────────────────────────────────┐
│                    CONSTITUTION (Inviolable)                    │
│  "No direct kubectl"  "Single writer only"  "Git is truth"     │
├─────────────────────────────────────────────────────────────────┤
│                    CONTRACTS (Component Rules)                  │
│  Coordinator: can update overlays/, cannot touch base/          │
│  Queue: must respect sync waves, dependency order               │
├─────────────────────────────────────────────────────────────────┤
│                    PLANS (Operational Patterns)                 │
│  single_service_update: health → deps → overlay → commit        │
│  multi_service_wave: correlation_id → wave-by-wave → monitor    │
├─────────────────────────────────────────────────────────────────┤
│                    MCP AGENT (Constrained Actor)                │
│  Tools = generated from contracts                               │
│  Every action = validated against constitution                  │
│  Every workflow = must follow plans                             │
└─────────────────────────────────────────────────────────────────┘
```

### 9.2 The Spec-Kit Hierarchy

```
platform-spec-kits/
├── constitution/           # Inviolable rules (like OS kernel permissions)
│   └── platform-constitution.yaml
├── specify/               # Component contracts (like API contracts)
│   ├── component-contracts.yaml
│   └── schemas/
├── plans/                 # Operational patterns (like runbooks)
│   └── deployment-patterns.yaml
├── tasks/                 # Concrete implementations
└── implementations/       # Reference code
```

### 9.3 Constitution Layer (Inviolable Rules)

```yaml
# constitution/platform-constitution.yaml
constitution:
  version: "1.0"
  
  non_goals:
    - "No direct kubectl to application namespaces"
    - "Argo CD is the reconciler, not a Git writer"
    - "Single writer to platform-config only"
    
  global_principles:
    - principle: "Git as single source of truth"
      description: "All desired state originates from platform-config repository"
      invariant: true
      
    - principle: "Kustomize overlays as mutation surface"
      description: "Only overlay patches and kustomization.yaml can be modified"
      allowed_paths:
        - "overlays/*/kustomization.yaml"
        - "overlays/*/*-patch.yaml"
        - "overlays/*/configmap-patches/*.yaml"
        
    - principle: "Write-time vs sync-time separation"
      description: |
        Write-time: Who writes to Git, when, and how (coordinator's job)
        Sync-time: How Argo CD orders and applies changes (Argo CD's job)
        
    - principle: "One logical change = one commit"
      description: "All related updates batched into a single atomic commit"
      
  enforcement_mechanisms:
    - "Coordinator validates all changes against constitution"
    - "Git pre-commit hooks validate path permissions"
    - "Argo CD Applications watch only allowed paths"
```

### 9.4 Contracts Layer (Component Rules)

```yaml
# specify/component-contracts.yaml
contracts:
  gitops_coordinator:
    role: "Single writer to platform-config"
    invariants:
      - "No direct kubectl to application namespaces"
      - "Always pull before writing"
      - "Retry on push failures (max 3 attempts)"
    allowed_operations:
      - "Update images[] in kustomization.yaml"
      - "Modify *-patch.yaml files in overlays/"
      - "Update ConfigMaps in configmap-patches/"
    prohibited_operations:
      - "Modify base/ directory"
      - "Modify apps/ directory"
      - "Modify CRDs"
      
  update_queue_manager:
    role: "Serialize and prioritize updates"
    invariants:
      - "Process updates in dependency order"
      - "Respect sync wave ordering"
    input: "UpdateRequest from REST API or Kafka"
    output: "Ordered list to coordinator"
    
  kafka_control_plane:
    role: "Deployment intent bus"
    invariants:
      - "All deployment intents go through Kafka"
      - "Status events published for observability"
    topics:
      - "deployment-events"
      - "deployment-status"
      - "deployment-commands"
```

### 9.5 Plans Layer (Operational Patterns)

```yaml
# plans/deployment-patterns.yaml
patterns:
  single_service_update:
    description: "Deploy a single service update"
    steps:
      - "Check service health"
      - "Check dependencies"
      - "Update Kustomize overlay"
      - "Commit with pattern: 'chore: update {service} to {version}'"
      - "Monitor Argo CD sync"
    rules:
      - "Must use coordinator API or Kafka event"
      - "Cannot bypass dependency checks"
      
  multi_service_wave:
    description: "Deploy multiple services in waves"
    steps:
      - "Generate correlation ID for the release"
      - "For each wave in dependency graph:"
      - "  Deploy all services in wave concurrently"
      - "  Wait for health checks"
      - "  Proceed to next wave"
    invariants:
      - "All services in wave must be healthy before next wave"
      - "Rollback affects entire correlation group"
      
  rollback_procedure:
    description: "Rollback a failed deployment"
    steps:
      - "Identify correlation ID to rollback"
      - "Find previous stable commit for each service"
      - "Update Kustomize overlays to previous images"
      - "Commit with pattern: 'fix: rollback {correlation_id}'"
    rules:
      - "Auto-rollback on health failure"
      - "Manual rollback requires approval for prod"
```

### 9.6 MCP Agent with Spec-Kit Constraints

```python
class MCPAgentWithSpecKits:
    """
    MCP agent that operates within spec-kit boundaries.
    Constitutional AI for infrastructure.
    """
    
    def __init__(self, spec_kit_path: str):
        # Load spec-kits at initialization
        self.constitution = self.load_constitution(spec_kit_path)
        self.contracts = self.load_contracts(spec_kit_path)
        self.plans = self.load_plans(spec_kit_path)
        
        # Available tools are constrained by contracts
        self.tools = self.build_tools_from_contracts()
        
    async def operate(self, observation: Observation) -> Action:
        """
        Agent observes, decides, and acts within spec boundaries
        """
        # 1. Observe within allowed observation points
        state = await self.observe_within_bounds(observation)
        
        # 2. Decide using plan patterns
        decision = await self.decide_using_plans(state)
        
        # 3. Validate decision against constitution
        if not await self.validate_against_constitution(decision):
            raise ConstitutionalViolation("Decision violates platform constitution")
        
        # 4. Execute using contract-defined interfaces
        result = await self.execute_within_contracts(decision)
        
        return result
    
    async def execute_within_contracts(self, decision: Decision):
        """Agent can only act through contract-defined interfaces"""
        contract = self.contracts.get(decision.component)
        
        if not contract:
            raise ContractNotFound(f"No contract for component: {decision.component}")
        
        # Check if operation is allowed by contract
        if decision.operation not in contract.allowed_operations:
            raise OperationNotAllowed(
                f"Operation {decision.operation} not allowed for {decision.component}. "
                f"Allowed: {contract.allowed_operations}"
            )
        
        # Execute through contract-defined interface
        return await self.execute_through_coordinator(decision)
```

### 9.7 Runtime Validation

```python
class SpecKitValidator:
    """Validates agent actions against spec-kits at runtime"""
    
    async def validate_action(self, agent: MCPAgent, action: AgentAction):
        # 1. Check against constitution (hard limits)
        constitutional_violations = await self.check_constitution(action)
        if constitutional_violations:
            raise ConstitutionalViolation(constitutional_violations)
        
        # 2. Check against component contracts (interface rules)
        contract_violations = await self.check_contracts(action)
        if contract_violations:
            raise ContractViolation(contract_violations)
        
        # 3. Check if follows defined plans (workflow compliance)
        plan_compliance = await self.check_plan_compliance(action)
        if not plan_compliance.valid:
            raise PlanViolation(plan_compliance.reasons)
        
        return ValidationResult(valid=True)
    
    async def check_constitution(self, action: AgentAction):
        """Check non-goals and principles"""
        violations = []
        
        # Non-goal: No direct kubectl
        if action.method == "kubectl" and action.operation not in ["get", "describe"]:
            violations.append("Direct kubectl operations violate constitution")
        
        # Principle: Git as source of truth
        if action.target == "kubernetes" and action.source != "git":
            violations.append("All changes must originate from Git")
        
        # Principle: Single writer
        if action.operation == "git_push" and action.actor != "gitops_coordinator":
            violations.append("Only coordinator can write to platform-config")
        
        return violations
```

### 9.8 MCP Tool Definitions (Generated from Contracts)

```yaml
# mcp-tools.yaml (Auto-generated from spec-kits)
tools:
  - name: "deploy_service"
    description: "Deploy a service using coordinator pattern"
    parameters:
      service:
        type: string
        pattern: "^[a-z-]+-service$"
      environment:
        type: string
        enum: ["dev", "staging", "prod"]
      image:
        type: string
        pattern: "^.*:[0-9]+\\.[0-9]+\\.[0-9]+$"
    implementation:
      type: "kafka_event"
      topic: "deployment-events"
    constraints:
      - "Must follow single_service_update pattern from plans/"
      - "Cannot deploy during maintenance windows"
      - "Must pass dependency checks"
      
  - name: "update_feature_flag"
    description: "Update feature flag configuration"
    parameters:
      service: string
      feature: string
      enabled: boolean
    implementation:
      type: "git_update"
      path: "overlays/{environment}/configmap-patches/{service}-features.yaml"
    constraints:
      - "Can only modify allowed config files"
      - "Rollback must be possible"
      
  - name: "initiate_rollback"
    description: "Rollback a failed deployment"
    parameters:
      correlation_id: string
      reason: string
    implementation:
      type: "coordinator_api"
      endpoint: "/api/v1/rollback"
    constraints:
      - "Only for unhealthy deployments"
      - "Requires approval for production"
```

### 9.9 Why This Matters

| Traditional Approach | Spec-Kits Approach |
|---------------------|-------------------|
| "Trust the agent" | "Agent operates within enforced boundaries" |
| Audit after the fact | Prevent violations at decision time |
| Human reviews agent actions | Constitution validates automatically |
| Free-form tool access | Tools generated from contracts |
| Hope agents follow runbooks | Plans are enforced, not suggested |

**Industry Parallels:**
- **Anthropic's Constitutional AI** - Constraining LLM outputs with principles
- **Google's Borg** - Quota and constraint enforcement  
- **AWS IAM** - Policy-based access control
- **Kubernetes RBAC** - Role-based permissions

**Our Innovation:** Applying Constitutional AI patterns to infrastructure automation, creating self-governing systems where AI agents physically cannot violate platform invariants.

### 9.10 Implementation Checklist

- [ ] Create `platform-spec-kits/` directory structure
- [ ] Define `constitution/platform-constitution.yaml` with non-goals and principles
- [ ] Define `specify/component-contracts.yaml` for each component
- [ ] Create `plans/deployment-patterns.yaml` with approved workflows
- [ ] Implement `SpecKitValidator` in GitOps Coordinator
- [ ] Add pre-commit hooks for path validation
- [ ] Generate MCP tools from contracts automatically
- [ ] Add constitution checks to all agent operations
- [ ] Create audit logging for constitutional violations

---

## Appendix A: File Checklist

### New Repositories
- [ ] `platform-config` - GitOps configuration repository

### New Services
- [ ] `gitops-coordinator` - Python/FastAPI singleton service
- [ ] `health-aggregator` - Health check aggregation service (can be part of coordinator)

### New Kafka Topics
- [ ] `cicd-deployment-events`
- [ ] `cicd-deployment-status`
- [ ] `cicd-health-events`

### New CRDs
- [ ] None required - existing CRDs are sufficient

### Modified Components
- [ ] CI pipelines - publish to Kafka
- [ ] Operator roles - add ConfigMap watching
- [ ] KafkaCluster CR - add CI/CD topics

---

## Appendix B: Architecture Decision Records

### ADR-001: Single Writer Pattern for Git
**Decision:** Only the GitOps Coordinator writes to `platform-config`  
**Rationale:** Prevents race conditions and merge conflicts  
**Alternatives Considered:** Multiple writers with locking, PR-based flow  

#### The Concurrent Update Problem

When multiple CI pipelines attempt to update the GitOps repository simultaneously, merge conflicts are inevitable:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WITHOUT SINGLE WRITER (The Problem)                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐           │
│  │ CI: user-svc    │   │ CI: identity    │   │ CI: blog-svc    │           │
│  │ git push v1.2   │   │ git push v2.0   │   │ git push v3.1   │           │
│  └────────┬────────┘   └────────┬────────┘   └────────┬────────┘           │
│           │                     │                     │                     │
│           │         T1: All push simultaneously       │                     │
│           └─────────────────────┼─────────────────────┘                     │
│                                 ▼                                           │
│                    ┌────────────────────────┐                               │
│                    │   💥 MERGE CONFLICT    │                               │
│                    │   platform-config      │                               │
│                    │   "Concurrent updates" │                               │
│                    └────────────┬───────────┘                               │
│                                 ▼                                           │
│                    ┌────────────────────────┐                               │
│                    │   ArgoCD: Sync Failed  │                               │
│                    │   Manual intervention  │                               │
│                    │   required!            │                               │
│                    └────────────────────────┘                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Industry approaches to this problem:**

| Approach | Drawback |
|----------|----------|
| Lock the whole repo | Serializes everything, creates bottleneck |
| Hope for the best | Random merge conflicts, manual fixes |
| Separate repos per service | Loses holistic view, complex ApplicationSets |
| PR-based flow | Slow, requires human approval, not truly automated |

#### The Single Writer Solution

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WITH SINGLE WRITER COORDINATOR                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐           │
│  │ CI: user-svc    │   │ CI: identity    │   │ CI: blog-svc    │           │
│  │ Kafka event     │   │ Kafka event     │   │ Kafka event     │           │
│  └────────┬────────┘   └────────┬────────┘   └────────┬────────┘           │
│           │                     │                     │                     │
│           └─────────────────────┼─────────────────────┘                     │
│                                 ▼                                           │
│                    ┌────────────────────────┐                               │
│                    │   Kafka Topic          │                               │
│                    │   cicd-deployment-events│                              │
│                    └────────────┬───────────┘                               │
│                                 ▼                                           │
│                    ┌────────────────────────┐                               │
│                    │   Redis Queue          │                               │
│                    │   (sorted by wave)     │                               │
│                    │   ─────────────────    │                               │
│                    │   Wave 0: identity     │  ◄── Identity first           │
│                    │   Wave 1: user         │  ◄── User depends on identity │
│                    │   Wave 2: blog         │  ◄── Blog depends on user     │
│                    └────────────┬───────────┘                               │
│                                 ▼                                           │
│                    ┌────────────────────────┐                               │
│                    │   GitOps Coordinator   │                               │
│                    │   ════════════════════ │                               │
│                    │   • Distributed lock   │                               │
│                    │   • Batches updates    │                               │
│                    │   • Single atomic write│                               │
│                    │   • Wave-ordered sync  │                               │
│                    └────────────┬───────────┘                               │
│                                 ▼                                           │
│                    ┌────────────────────────┐                               │
│                    │   ✅ Clean Git History │                               │
│                    │   platform-config      │                               │
│                    │   No conflicts ever    │                               │
│                    └────────────┬───────────┘                               │
│                                 ▼                                           │
│                    ┌────────────────────────┐                               │
│                    │   ArgoCD: Sync Success │                               │
│                    │   Services deploy in   │                               │
│                    │   dependency order     │                               │
│                    └────────────────────────┘                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Key implementation patterns:**

```python
# Redis distributed lock prevents multiple coordinator instances
lock_acquired = redis.set('gitops:processing_lock', '1', nx=True, ex=300)

# Sorted set queues updates by: (wave * 1000000) + timestamp
# This ensures dependency order while maintaining FIFO within each wave
score = update.sync_wave * 1000000 + update.timestamp.timestamp()
redis.zadd('gitops:update_queue', {json.dumps(update_data): score})

# Batch updates per environment to minimize commits
for env, updates in env_updates.items():
    await self.apply_environment_updates(env, updates)
    self.repo.index.commit(f"Batch update: {len(updates)} services in {env}")
```

**Result:** This is how Netflix's Spinnaker and Google's internal deployment systems handle concurrent updates at scale.

### ADR-002: Python for GitOps Coordinator
**Decision:** Use Python with FastAPI  
**Rationale:** Excellent Git libraries (GitPython), async Kafka support, aligns with Ansible  
**Alternatives Considered:** NestJS (TypeScript), Go  

### ADR-003: Kustomize over Helm
**Decision:** Use Kustomize for overlays  
**Rationale:** Native kubectl support, simpler patching model, Argo CD native support  
**Alternatives Considered:** Helm with values files  

### ADR-004: App-of-Apps Pattern
**Decision:** Use Argo CD app-of-apps  
**Rationale:** Single source for all applications, hierarchical management  
**Alternatives Considered:** ApplicationSets, individual applications  

---

*Document Version: 1.0*  
*Last Updated: January 12, 2026*
