#!/bin/bash
# Complete setup script for platform-config GitOps repository
# Run this AFTER Pulumi has created the infrastructure

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║         Platform-Config GitOps Repository Setup              ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PULUMI_DIR="${REPO_ROOT}/../infrastructure/pulumi"

# Change to Pulumi directory to get outputs
cd "$PULUMI_DIR"

echo -e "\n${YELLOW}📦 Fetching Pulumi outputs...${NC}"

# Get Pulumi outputs (assuming you've already run pulumi up)
ECR_REGISTRY=$(pulumi stack output ecrRegistryUrl 2>/dev/null || echo "")
GITHUB_ROLE_ARN=$(pulumi stack output githubActionsRoleArn 2>/dev/null || echo "")
CLUSTER_NAME=$(pulumi stack output clusterName 2>/dev/null || echo "kubeadm_ec2_cluster")

if [ -z "$ECR_REGISTRY" ] || [ -z "$GITHUB_ROLE_ARN" ]; then
    echo -e "${RED}❌ Could not get Pulumi outputs.${NC}"
    echo -e "${YELLOW}Please run 'pulumi up' first to create the infrastructure.${NC}"
    echo ""
    echo "Required steps:"
    echo "  1. cd $PULUMI_DIR"
    echo "  2. pulumi config set kube-cluster-deployment:githubOrg <your-github-username>"
    echo "  3. pulumi config set kube-cluster-deployment:githubRepo platform-config"
    echo "  4. pulumi up"
    echo "  5. Run this script again"
    exit 1
fi

echo -e "${GREEN}✅ ECR Registry: ${ECR_REGISTRY}${NC}"
echo -e "${GREEN}✅ GitHub Actions Role: ${GITHUB_ROLE_ARN}${NC}"
echo -e "${GREEN}✅ Cluster Name: ${CLUSTER_NAME}${NC}"

# Change to repo root
cd "$REPO_ROOT"

# Check if gh CLI is available
if ! command -v gh &> /dev/null; then
    echo -e "${RED}❌ GitHub CLI (gh) is not installed.${NC}"
    echo "Install it with: brew install gh"
    exit 1
fi

# Check if authenticated
if ! gh auth status &> /dev/null; then
    echo -e "${YELLOW}🔐 Please authenticate with GitHub CLI...${NC}"
    gh auth login
fi

# Initialize git if needed
if [ ! -d ".git" ]; then
    echo -e "\n${YELLOW}📝 Initializing git repository...${NC}"
    git init
    git add .
    git commit -m "Initial commit: GitOps platform-config structure"
fi

# Create private GitHub repo
GITHUB_USER=$(gh api user --jq '.login')
REPO_NAME="platform-config"

echo -e "\n${YELLOW}📤 Creating private GitHub repository...${NC}"

if gh repo view "${GITHUB_USER}/${REPO_NAME}" &> /dev/null; then
    echo -e "${GREEN}Repository ${GITHUB_USER}/${REPO_NAME} already exists${NC}"
else
    gh repo create "$REPO_NAME" --private --source=. --push --description "GitOps configuration for Kubernetes platform"
    echo -e "${GREEN}✅ Created private repository: ${GITHUB_USER}/${REPO_NAME}${NC}"
fi

# Set repository variables (not secrets - these are non-sensitive)
echo -e "\n${YELLOW}🔧 Configuring GitHub repository variables...${NC}"

gh variable set AWS_ROLE_ARN --body "$GITHUB_ROLE_ARN" 2>/dev/null || \
    echo "AWS_ROLE_ARN variable may already exist"

gh variable set ECR_REGISTRY --body "$ECR_REGISTRY" 2>/dev/null || \
    echo "ECR_REGISTRY variable may already exist"

gh variable set CLUSTER_NAME --body "$CLUSTER_NAME" 2>/dev/null || \
    echo "CLUSTER_NAME variable may already exist"

gh variable set AWS_REGION --body "eu-west-2" 2>/dev/null || \
    echo "AWS_REGION variable may already exist"

echo -e "${GREEN}✅ Repository variables configured${NC}"

# Generate SSH key for deployments (optional)
SSH_KEY_PATH="$HOME/.ssh/id_ed25519_platform_config"
if [ ! -f "$SSH_KEY_PATH" ]; then
    echo -e "\n${YELLOW}🔑 Generating SSH deploy key...${NC}"
    ssh-keygen -t ed25519 -C "platform-config-deploy" -f "$SSH_KEY_PATH" -N ""
    echo -e "${GREEN}✅ SSH key generated at: ${SSH_KEY_PATH}${NC}"
else
    echo -e "${GREEN}✅ SSH key already exists at: ${SSH_KEY_PATH}${NC}"
fi

# Add deploy key to repository
echo -e "\n${YELLOW}🔑 Adding deploy key to repository...${NC}"
gh repo deploy-key add "${SSH_KEY_PATH}.pub" --title "Platform Config Deploy Key" --allow-write 2>/dev/null || \
    echo "Deploy key may already exist"

echo -e "\n${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                    Setup Complete! 🎉                        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"

echo -e "\n${GREEN}📋 Summary:${NC}"
echo "  • Repository: https://github.com/${GITHUB_USER}/${REPO_NAME}"
echo "  • ECR Registry: ${ECR_REGISTRY}"
echo "  • GitHub Actions Role: ${GITHUB_ROLE_ARN}"
echo "  • Deploy Key: ${SSH_KEY_PATH}"

echo -e "\n${YELLOW}📝 Next Steps:${NC}"
echo "  1. Push your code: git push -u origin main"
echo "  2. Configure Argo CD to watch this repository"
echo "  3. Add workflow triggers in your service repositories"

echo -e "\n${GREEN}🔐 GitHub Actions OIDC is configured - no static AWS credentials needed!${NC}"
echo "  Workflows will use: role-to-assume: \${AWS_ROLE_ARN}"
