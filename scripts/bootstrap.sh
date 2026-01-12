#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🚀 Platform Config Bootstrap Script${NC}"
echo "======================================"

# Configuration - UPDATE THESE VALUES
ECR_ACCOUNT_ID="${AWS_ACCOUNT_ID:-YOUR_ACCOUNT_ID}"
ECR_REGION="${AWS_REGION:-us-east-1}"
GITHUB_ORG="${GITHUB_ORG:-YOUR_ORG}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Function to update ECR references
update_ecr_references() {
    echo -e "\n${YELLOW}📝 Updating ECR references...${NC}"
    
    # Update kustomization files
    find "$ROOT_DIR/overlays" -name "kustomization.yaml" -exec \
        sed -i '' \
        -e "s/ACCOUNT_ID/${ECR_ACCOUNT_ID}/g" \
        -e "s/REGION/${ECR_REGION}/g" \
        {} \;
    
    echo -e "${GREEN}✅ Updated ECR account and region in overlays${NC}"
}

# Function to update GitHub org references
update_github_references() {
    echo -e "\n${YELLOW}📝 Updating GitHub references...${NC}"
    
    find "$ROOT_DIR/apps" -name "*.yaml" -exec \
        sed -i '' "s/YOUR_ORG/${GITHUB_ORG}/g" {} \;
    
    echo -e "${GREEN}✅ Updated GitHub org in Argo CD apps${NC}"
}

# Function to initialize Git repository
init_git_repo() {
    echo -e "\n${YELLOW}📦 Initializing Git repository...${NC}"
    
    cd "$ROOT_DIR"
    
    if [ ! -d ".git" ]; then
        git init
        git add .
        git commit -m "Initial platform-config setup"
        echo -e "${GREEN}✅ Git repository initialized${NC}"
    else
        echo -e "${YELLOW}⚠️  Git already initialized${NC}"
    fi
}

# Function to create .gitignore
create_gitignore() {
    cat > "$ROOT_DIR/.gitignore" << 'EOF'
# Local files
.env
*.local

# Editor files
.idea/
.vscode/
*.swp
*.swo

# OS files
.DS_Store
Thumbs.db

# Temporary files
/tmp/
*.tmp
EOF
    echo -e "${GREEN}✅ Created .gitignore${NC}"
}

# Function to create CODEOWNERS
create_codeowners() {
    mkdir -p "$ROOT_DIR/.github"
    cat > "$ROOT_DIR/.github/CODEOWNERS" << 'EOF'
# Platform team owns everything
* @platform-team

# Production requires additional approval
/overlays/prod/ @platform-leads @sre-team

# Rules changes need review
**/rules.json @platform-leads
EOF
    echo -e "${GREEN}✅ Created CODEOWNERS${NC}"
}

# Main execution
echo -e "\n${BLUE}Configuration:${NC}"
echo "  ECR Account ID: $ECR_ACCOUNT_ID"
echo "  ECR Region: $ECR_REGION"
echo "  GitHub Org: $GITHUB_ORG"

read -p "Continue with these settings? (y/n) " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    update_ecr_references
    update_github_references
    create_gitignore
    create_codeowners
    init_git_repo
    
    echo -e "\n${GREEN}🎉 Bootstrap complete!${NC}"
    echo -e "\nNext steps:"
    echo "  1. Create GitHub repository: gh repo create $GITHUB_ORG/platform-config --private"
    echo "  2. Add remote: git remote add origin git@github.com:$GITHUB_ORG/platform-config.git"
    echo "  3. Push: git push -u origin main"
    echo "  4. Install Argo CD and apply apps/app-of-apps.yaml"
else
    echo -e "${YELLOW}Aborted${NC}"
fi
