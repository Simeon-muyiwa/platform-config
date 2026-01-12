#!/bin/bash
# GitHub Repository Setup Script for platform-config
# This script sets up SSH, creates the private repo, and configures GitHub Actions secrets

set -e

REPO_NAME="platform-config"
GITHUB_USERNAME="${GITHUB_USERNAME:-your-github-username}"  # Override with your username
AWS_ACCOUNT_ID="939217651725"
AWS_REGION="eu-west-2"

echo "=========================================="
echo "Platform Config GitHub Setup"
echo "=========================================="

# Step 1: Check/Generate SSH Key
echo ""
echo "Step 1: SSH Key Setup"
echo "---------------------"

if [ ! -f ~/.ssh/id_ed25519_github ]; then
    echo "Generating new SSH key for GitHub..."
    read -p "Enter your GitHub email: " github_email
    ssh-keygen -t ed25519 -C "$github_email" -f ~/.ssh/id_ed25519_github -N ""
    
    # Add to SSH config
    cat >> ~/.ssh/config << 'EOF'

# GitHub
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519_github
  IdentitiesOnly yes
EOF
    
    echo ""
    echo "✅ SSH key generated!"
    echo ""
    echo "📋 Add this public key to GitHub (Settings → SSH Keys):"
    echo "----------------------------------------"
    cat ~/.ssh/id_ed25519_github.pub
    echo "----------------------------------------"
    echo ""
    read -p "Press Enter after adding the key to GitHub..."
else
    echo "✅ SSH key already exists at ~/.ssh/id_ed25519_github"
fi

# Start SSH agent and add key
eval "$(ssh-agent -s)" > /dev/null 2>&1
ssh-add ~/.ssh/id_ed25519_github 2>/dev/null || true

# Test GitHub connection
echo ""
echo "Testing GitHub SSH connection..."
ssh -T git@github.com 2>&1 | grep -q "successfully authenticated" && echo "✅ GitHub SSH connection successful!" || echo "⚠️  SSH test returned non-zero (this is often normal)"

# Step 2: Install GitHub CLI if needed
echo ""
echo "Step 2: GitHub CLI Setup"
echo "------------------------"

if ! command -v gh &> /dev/null; then
    echo "Installing GitHub CLI..."
    brew install gh
fi

# Check auth status
if ! gh auth status &> /dev/null; then
    echo "Authenticating with GitHub..."
    gh auth login
fi

echo "✅ GitHub CLI authenticated"

# Step 3: Initialize and create repo
echo ""
echo "Step 3: Repository Creation"
echo "---------------------------"

cd "$(dirname "$0")/.."

if [ ! -d .git ]; then
    echo "Initializing git repository..."
    git init
    git add .
    git commit -m "Initial commit: Platform config structure"
fi

# Check if remote exists
if ! git remote get-url origin &> /dev/null; then
    echo "Creating private GitHub repository..."
    gh repo create "$REPO_NAME" --private --source=. --remote=origin --push
    echo "✅ Repository created and pushed!"
else
    echo "✅ Remote already configured: $(git remote get-url origin)"
fi

# Step 4: Configure GitHub Actions secrets
echo ""
echo "Step 4: GitHub Actions Secrets"
echo "------------------------------"

echo "Setting up repository secrets for GitHub Actions..."

# AWS credentials for ECR access
read -p "Enter AWS_ACCESS_KEY_ID for CI/CD (or press Enter to skip): " aws_key
if [ -n "$aws_key" ]; then
    read -sp "Enter AWS_SECRET_ACCESS_KEY: " aws_secret
    echo ""
    
    gh secret set AWS_ACCESS_KEY_ID --body "$aws_key"
    gh secret set AWS_SECRET_ACCESS_KEY --body "$aws_secret"
    gh secret set AWS_REGION --body "$AWS_REGION"
    gh secret set AWS_ACCOUNT_ID --body "$AWS_ACCOUNT_ID"
    
    echo "✅ AWS secrets configured!"
fi

# ECR Registry URL
gh secret set ECR_REGISTRY --body "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com" 2>/dev/null || true

echo ""
echo "=========================================="
echo "✅ Setup Complete!"
echo "=========================================="
echo ""
echo "Repository: https://github.com/${GITHUB_USERNAME}/${REPO_NAME}"
echo "ECR Registry: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
echo ""
echo "Next steps:"
echo "1. Run ./scripts/setup-ecr.sh to create ECR repositories"
echo "2. Create a CI/CD user in AWS IAM with ECR push permissions"
echo "3. Add the CI/CD credentials as GitHub secrets"
echo "4. Push your first image to test the pipeline"
