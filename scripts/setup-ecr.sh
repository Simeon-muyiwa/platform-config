#!/bin/bash
# ECR Repository Setup Script
# Run this once to create all required ECR repositories

set -e

AWS_ACCOUNT_ID="939217651725"
AWS_REGION="eu-west-2"

# List of repositories to create
REPOSITORIES=(
    "webapp-operator"
    "identity-service"
    "user-service"
    "blog-service"
    "frontend"
    "gitops-coordinator"
    "health-aggregator"
)

echo "Creating ECR repositories in ${AWS_REGION}..."

for repo in "${REPOSITORIES[@]}"; do
    echo "Creating repository: ${repo}"
    aws ecr create-repository \
        --repository-name "${repo}" \
        --region "${AWS_REGION}" \
        --image-scanning-configuration scanOnPush=true \
        --encryption-configuration encryptionType=AES256 \
        2>/dev/null || echo "  Repository ${repo} already exists"
    
    # Set lifecycle policy to keep only last 10 images
    aws ecr put-lifecycle-policy \
        --repository-name "${repo}" \
        --region "${AWS_REGION}" \
        --lifecycle-policy-text '{
            "rules": [
                {
                    "rulePriority": 1,
                    "description": "Keep last 10 images",
                    "selection": {
                        "tagStatus": "any",
                        "countType": "imageCountMoreThan",
                        "countNumber": 10
                    },
                    "action": {
                        "type": "expire"
                    }
                }
            ]
        }' 2>/dev/null || echo "  Lifecycle policy already set for ${repo}"
done

echo ""
echo "✅ ECR repositories created!"
echo ""
echo "Registry URL: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
echo ""
echo "To authenticate Docker:"
echo "aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
