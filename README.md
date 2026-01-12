# Platform Configuration Repository

This repository is the **single source of truth** for all Kubernetes deployments managed by Argo CD.

## Repository Structure

```
platform-config/
├── base/                    # Immutable base definitions
│   ├── crds/               # CRD definitions (if managing CRDs here)
│   ├── operator/           # Ansible operator manifests
│   ├── identity-service/   # Base CR for identity-service
│   ├── user-service/       # Base CR for user-service
│   ├── blog-service/       # Base CR for blog-service
│   ├── frontend/           # Base CR for frontend
│   └── kafka/              # Base KafkaCluster CR
├── overlays/               # Environment-specific configurations
│   ├── dev/                # Development overlay
│   ├── staging/            # Staging overlay
│   └── prod/               # Production overlay
├── apps/                   # Argo CD Application definitions
│   └── app-of-apps.yaml    # Parent application
└── scripts/                # Utility scripts
```

## Key Principles

1. **Single Writer**: Only the GitOps Coordinator writes to this repository
2. **Kustomize Overlays**: Environment differences are managed via patches
3. **rules.json**: Runtime behavior configuration per environment
4. **App-of-Apps**: Argo CD manages all applications via a parent app

## Quick Start

```bash
# Validate manifests
./scripts/validate.sh

# Preview kustomize output for prod
kustomize build overlays/prod

# Apply directly (for testing - use Argo CD in production)
kustomize build overlays/prod | kubectl apply -f -
```

## Environments

| Environment | Purpose | Sync Policy |
|-------------|---------|-------------|
| dev | Development testing | Manual sync |
| staging | Pre-production validation | Auto sync |
| prod | Production | Auto sync with prune disabled |

## Related Documentation

- [GitOps Implementation Plan](../docs/GITOPS-IMPLEMENTATION-PLAN.md)
- [Deployment Guide](../docs/DEPLOYMENT-GUIDE.md)
