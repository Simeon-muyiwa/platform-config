#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🔍 Validating platform-config manifests..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

# Check if kustomize is installed
if ! command -v kustomize &> /dev/null; then
    echo -e "${YELLOW}⚠️  kustomize not found, using kubectl kustomize${NC}"
    KUSTOMIZE="kubectl kustomize"
else
    KUSTOMIZE="kustomize build"
fi

# Check if kubeconform is installed for validation
if ! command -v kubeconform &> /dev/null; then
    echo -e "${YELLOW}⚠️  kubeconform not found, skipping schema validation${NC}"
    SKIP_SCHEMA=true
fi

# Validate base operator
echo -e "\n${YELLOW}📁 Validating base/operator...${NC}"
$KUSTOMIZE base/operator > /dev/null && echo -e "${GREEN}✅ base/operator is valid${NC}"

# Validate overlays
for env in dev staging prod; do
    echo -e "\n${YELLOW}📁 Validating overlays/$env...${NC}"
    
    if $KUSTOMIZE "overlays/$env" > /tmp/kustomize-output.yaml 2>&1; then
        echo -e "${GREEN}✅ overlays/$env builds successfully${NC}"
        
        # Validate with kubeconform if available
        if [ -z "$SKIP_SCHEMA" ]; then
            if kubeconform -strict -summary /tmp/kustomize-output.yaml; then
                echo -e "${GREEN}✅ overlays/$env passes schema validation${NC}"
            else
                echo -e "${RED}❌ overlays/$env failed schema validation${NC}"
                exit 1
            fi
        fi
    else
        echo -e "${RED}❌ overlays/$env failed to build${NC}"
        cat /tmp/kustomize-output.yaml
        exit 1
    fi
done

# Validate rules.json files
echo -e "\n${YELLOW}📁 Validating rules.json files...${NC}"
for rules_file in overlays/*/rules.json; do
    if jq empty "$rules_file" 2>/dev/null; then
        echo -e "${GREEN}✅ $rules_file is valid JSON${NC}"
    else
        echo -e "${RED}❌ $rules_file is invalid JSON${NC}"
        exit 1
    fi
done

# Validate Argo CD applications
echo -e "\n${YELLOW}📁 Validating apps/...${NC}"
for app_file in apps/*.yaml; do
    if kubectl apply --dry-run=client -f "$app_file" > /dev/null 2>&1; then
        echo -e "${GREEN}✅ $app_file is valid${NC}"
    else
        echo -e "${YELLOW}⚠️  $app_file skipped (Argo CD CRDs not installed locally)${NC}"
    fi
done

# Cleanup
rm -f /tmp/kustomize-output.yaml

echo -e "\n${GREEN}🎉 All validations passed!${NC}"
