#!/bin/bash
# Azure mTLS Lab Deployment Script
# This script orchestrates the complete deployment of the mTLS lab environment

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
DEFAULT_RESOURCE_GROUP="rg-mtls-lab"
DEFAULT_LOCATION="eastus"
DEPLOYMENT_NAME="mtls-lab-deployment-$(date +%s)"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Azure mTLS Lab Deployment${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Prompt for resource group
echo -e "${YELLOW}Resource Group [${DEFAULT_RESOURCE_GROUP}]: ${NC}\c"
read -r INPUT_RG
RESOURCE_GROUP="${INPUT_RG:-$DEFAULT_RESOURCE_GROUP}"

# Prompt for location
echo -e "${YELLOW}Location [${DEFAULT_LOCATION}]: ${NC}\c"
read -r INPUT_LOCATION
LOCATION="${INPUT_LOCATION:-$DEFAULT_LOCATION}"

echo ""
echo -e "  Resource Group: ${BLUE}${RESOURCE_GROUP}${NC}"
echo -e "  Location:       ${BLUE}${LOCATION}${NC}"
echo ""

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
echo -e "${YELLOW}[STEP 1/9] Checking prerequisites...${NC}"

if ! command_exists az; then
    echo -e "${RED}Error: Azure CLI is not installed${NC}"
    echo "Please install Azure CLI: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

if ! command_exists openssl; then
    echo -e "${RED}Error: OpenSSL is not installed${NC}"
    exit 1
fi

if ! command_exists jq; then
    echo -e "${RED}Error: jq is not installed${NC}"
    echo "Please install jq for JSON processing"
    exit 1
fi

echo -e "${GREEN}✓ All prerequisites met${NC}"

# Check Azure login
echo -e "${YELLOW}[STEP 2/9] Checking Azure authentication...${NC}"
if ! az account show &>/dev/null; then
    echo -e "${YELLOW}Not logged in. Initiating Azure login...${NC}"
    az login
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
echo -e "${GREEN}✓ Logged into Azure${NC}"
echo -e "  Subscription: ${BLUE}${SUBSCRIPTION_NAME}${NC}"
echo -e "  ID: ${BLUE}${SUBSCRIPTION_ID}${NC}"
echo ""

# Generate SSH key if it doesn't exist
echo -e "${YELLOW}[STEP 3/9] Checking SSH key...${NC}"
SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"
if [ ! -f "$SSH_KEY_PATH" ]; then
    echo -e "${YELLOW}SSH key not found. Generating new SSH key...${NC}"
    ssh-keygen -t rsa -b 4096 -f "$HOME/.ssh/id_rsa" -N ""
fi
SSH_PUBLIC_KEY=$(cat $SSH_KEY_PATH)
echo -e "${GREEN}✓ SSH key available${NC}"

# Generate certificates
echo -e "${YELLOW}[STEP 4/9] Generating certificates...${NC}"
if [ ! -d "certs" ]; then
    ./generateCerts.sh
else
    echo -e "${BLUE}Certificates directory already exists. Skipping generation.${NC}"
    echo -e "${BLUE}To regenerate, delete the 'certs' directory and run this script again.${NC}"
fi
echo -e "${GREEN}✓ Certificates ready${NC}"

# Create resource group
echo -e "${YELLOW}[STEP 5/9] Creating resource group...${NC}"
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION \
  --output table

echo -e "${GREEN}✓ Resource group created${NC}"

# Deploy Bicep template
echo -e "${YELLOW}[STEP 6/9] Deploying Azure resources (this may take 10-15 minutes)...${NC}"
DEPLOYMENT_OUTPUT=$(az deployment group create \
  --name $DEPLOYMENT_NAME \
  --resource-group $RESOURCE_GROUP \
  --template-file main.bicep \
  --parameters sshPublicKey="$SSH_PUBLIC_KEY" \
  --output json)

echo -e "${GREEN}✓ Azure resources deployed${NC}"

# Extract outputs
echo -e "${YELLOW}[STEP 7/9] Extracting deployment information...${NC}"
KEY_VAULT_NAME=$(echo $DEPLOYMENT_OUTPUT | jq -r '.properties.outputs.keyVaultName.value')
APP_GW_NAME=$(echo $DEPLOYMENT_OUTPUT | jq -r '.properties.outputs.appGwName.value')
APP_GW_FQDN=$(echo $DEPLOYMENT_OUTPUT | jq -r '.properties.outputs.appGwFqdn.value')
HOST1_NAME=$(echo $DEPLOYMENT_OUTPUT | jq -r '.properties.outputs.host1Name.value')
HOST2_NAME=$(echo $DEPLOYMENT_OUTPUT | jq -r '.properties.outputs.host2Name.value')
HOST1_IP=$(echo $DEPLOYMENT_OUTPUT | jq -r '.properties.outputs.host1PrivateIp.value')
HOST2_IP=$(echo $DEPLOYMENT_OUTPUT | jq -r '.properties.outputs.host2PrivateIp.value')

echo -e "${GREEN}✓ Deployment information extracted${NC}"

# Get current user's Object ID for Key Vault permissions
USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

# Assign Key Vault permissions to current user
echo -e "${YELLOW}[STEP 8/9] Configuring Key Vault permissions...${NC}"
az role assignment create \
  --role "Key Vault Administrator" \
  --assignee $USER_OBJECT_ID \
  --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KEY_VAULT_NAME \
  --output none

# Wait for RBAC propagation
echo -e "${BLUE}Waiting for RBAC propagation (30 seconds)...${NC}"
sleep 30

# Upload certificates to Key Vault
echo -e "${YELLOW}Uploading certificates to Key Vault...${NC}"

# Upload CA certificate as a secret (for backend servers)
az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "ca-cert" \
  --file certs/ca.crt \
  --output none

# Upload host1 certificate and key
az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "host1-cert" \
  --file certs/host1.crt \
  --output none

az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "host1-key" \
  --file certs/host1.key \
  --output none

# Upload host2 certificate and key
az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "host2-cert" \
  --file certs/host2.crt \
  --output none

az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "host2-key" \
  --file certs/host2.key \
  --output none

# Upload Application Gateway PFX certificate
az keyvault certificate import \
  --vault-name $KEY_VAULT_NAME \
  --name "appgw-ssl-cert" \
  --file certs/appgw-ssl.pfx \
  --output none

# Upload trusted root for backend authentication
az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "backend-root-cert" \
  --file certs/ca.crt \
  --output none

echo -e "${GREEN}✓ Certificates uploaded to Key Vault${NC}"

# Deploy certificates to VMs using Azure CLI
echo -e "${YELLOW}[STEP 9/9] Deploying certificates to backend VMs...${NC}"

# Function to deploy certificates to a VM
deploy_certs_to_vm() {
    local VM_NAME=$1
    local CERT_NAME=$2
    
    echo -e "${BLUE}  Deploying certificates to $VM_NAME...${NC}"
    
    # Create deployment script
    cat > /tmp/deploy-vm-certs.sh << 'EOFSCRIPT'
#!/bin/bash
# Download certificates from Key Vault and configure nginx

VAULT_NAME="__VAULT_NAME__"
HOST_NAME="__HOST_NAME__"

# Install Azure CLI if not present
if ! command -v az &> /dev/null; then
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
fi

# Login using VM managed identity (will be added in future enhancement)
# For now, we'll use a different approach - uploading via custom script extension

echo "Certificate deployment script executed on $HOST_NAME"
EOFSCRIPT
    
    sed -i "s/__VAULT_NAME__/$KEY_VAULT_NAME/g" /tmp/deploy-vm-certs.sh
    sed -i "s/__HOST_NAME__/$CERT_NAME/g" /tmp/deploy-vm-certs.sh
    
    # For this lab, we'll use run-command to deploy certificates
    # Build a full chain: server cert + CA cert (required by App Gateway to validate the backend chain)
    CA_CERT=$(cat certs/ca.crt | base64 -w 0)
    CHAIN_CERT=$(cat certs/${CERT_NAME}.crt certs/ca.crt | base64 -w 0)
    SERVER_KEY=$(cat certs/${CERT_NAME}.key | base64 -w 0)
    
    az vm run-command invoke \
      --resource-group $RESOURCE_GROUP \
      --name $VM_NAME \
      --command-id RunShellScript \
      --scripts \
        "echo '$CA_CERT' | base64 -d | sudo tee /etc/nginx/ssl/ca.crt > /dev/null" \
        "echo '$CHAIN_CERT' | base64 -d | sudo tee /etc/nginx/ssl/server.crt > /dev/null" \
        "echo '$SERVER_KEY' | base64 -d | sudo tee /etc/nginx/ssl/server.key > /dev/null" \
        "sudo chmod 600 /etc/nginx/ssl/server.key" \
        "sudo chown www-data:www-data /etc/nginx/ssl/*" \
        "sudo systemctl restart nginx" \
        "sudo systemctl status nginx --no-pager" \
      --output none
    
    echo -e "${GREEN}  ✓ Certificates deployed to $VM_NAME${NC}"
}

deploy_certs_to_vm "$HOST1_NAME" "host1"
deploy_certs_to_vm "$HOST2_NAME" "host2"

echo -e "${GREEN}✓ Certificates deployed to all VMs${NC}"

# Display completion message
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Resource Group:${NC} $RESOURCE_GROUP"
echo -e "${BLUE}Location:${NC} $LOCATION"
echo -e "${BLUE}Key Vault:${NC} $KEY_VAULT_NAME"
echo -e "${BLUE}Application Gateway:${NC} $APP_GW_NAME"
echo -e "${BLUE}Application Gateway FQDN:${NC} $APP_GW_FQDN"
echo ""
echo -e "${BLUE}Backend Servers:${NC}"
echo -e "  🔴 Host1 (Red):  $HOST1_NAME ($HOST1_IP)"
echo -e "  🔵 Host2 (Blue): $HOST2_NAME ($HOST2_IP)"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Wait a few minutes for all services to fully start"
echo "2. Test the Application Gateway endpoint:"
echo -e "   ${GREEN}curl http://$APP_GW_FQDN${NC}"
echo ""
echo "3. To configure mTLS on Application Gateway, see README.md"
echo ""
echo -e "${YELLOW}Note:${NC} Application Gateway is currently in HTTP mode."
echo "Follow the README.md instructions to enable HTTPS with mTLS."
echo ""

# Save deployment info
cat > deployment-info.json << EOF
{
  "resourceGroup": "$RESOURCE_GROUP",
  "location": "$LOCATION",
  "keyVaultName": "$KEY_VAULT_NAME",
  "appGatewayName": "$APP_GW_NAME",
  "appGatewayFqdn": "$APP_GW_FQDN",
  "host1": {
    "name": "$HOST1_NAME",
    "privateIp": "$HOST1_IP"
  },
  "host2": {
    "name": "$HOST2_NAME",
    "privateIp": "$HOST2_IP"
  },
  "deploymentDate": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo -e "${GREEN}Deployment information saved to deployment-info.json${NC}"
echo ""
