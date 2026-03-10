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
echo -e "${YELLOW}[STEP 1/10] Checking prerequisites...${NC}"

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
echo -e "${YELLOW}[STEP 2/10] Checking Azure authentication...${NC}"
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

# Generate a lab-specific SSH key pair stored in certs/
echo -e "${YELLOW}[STEP 3/10] Generating SSH key pair for lab VMs...${NC}"
mkdir -p certs
SSH_PRIVATE_KEY_PATH="certs/vm-ssh-key"
SSH_PUBLIC_KEY_PATH="certs/vm-ssh-key.pub"
if [ ! -f "$SSH_PRIVATE_KEY_PATH" ]; then
    echo -e "${YELLOW}Generating new SSH key pair for this lab...${NC}"
    ssh-keygen -t rsa -b 4096 -f "$SSH_PRIVATE_KEY_PATH" -N "" -C "azure-appgw-mtls-lab"
    chmod 600 "$SSH_PRIVATE_KEY_PATH"
fi
SSH_PUBLIC_KEY=$(cat "$SSH_PUBLIC_KEY_PATH")
echo -e "${GREEN}✓ Lab SSH key pair ready${NC}"
echo -e "  Private key: ${BLUE}${SSH_PRIVATE_KEY_PATH}${NC} (will be uploaded to Key Vault)"
echo -e "  Public key:  ${BLUE}${SSH_PUBLIC_KEY_PATH}${NC}"

# Generate certificates
echo -e "${YELLOW}[STEP 4/10] Generating certificates...${NC}"
if [ ! -f "certs/ca.crt" ]; then
    ./generateCerts.sh
else
    echo -e "${BLUE}Certificates already exist. Skipping generation.${NC}"
    echo -e "${BLUE}To regenerate, delete the 'certs' directory and run this script again.${NC}"
fi
echo -e "${GREEN}✓ Certificates ready${NC}"

# Create resource group
echo -e "${YELLOW}[STEP 5/10] Creating resource group...${NC}"
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION \
  --output table

echo -e "${GREEN}✓ Resource group created${NC}"

# Deploy Bicep template
echo -e "${YELLOW}[STEP 6/10] Deploying Azure resources (this may take 10-15 minutes)...${NC}"

# Generate Windows jumpbox admin password (meets complexity: upper, lower, digit, special)
RAND_HEX=$(openssl rand -hex 6)
JUMPBOX_ADMIN_PASSWORD="JumpBox${RAND_HEX}!Az"

CA_CERT_DATA=$(base64 -w 0 certs/ca.crt)
APP_GW_SSL_CERT_DATA=$(base64 -w 0 certs/appgw-ssl.pfx)
HOST1_CERT_DATA=$(base64 -w 0 certs/host1.crt)
HOST1_KEY_DATA=$(base64 -w 0 certs/host1.key)
HOST2_CERT_DATA=$(base64 -w 0 certs/host2.crt)
HOST2_KEY_DATA=$(base64 -w 0 certs/host2.key)

DEPLOYMENT_OUTPUT=$(az deployment group create \
  --name $DEPLOYMENT_NAME \
  --resource-group $RESOURCE_GROUP \
  --template-file main.bicep \
  --parameters \
    sshPublicKey="$SSH_PUBLIC_KEY" \
    caCertData="$CA_CERT_DATA" \
    appGwSslCertData="$APP_GW_SSL_CERT_DATA" \
    appGwSslCertPassword="" \
    jumpboxAdminPassword="$JUMPBOX_ADMIN_PASSWORD" \
    host1CertData="$HOST1_CERT_DATA" \
    host1KeyData="$HOST1_KEY_DATA" \
    host2CertData="$HOST2_CERT_DATA" \
    host2KeyData="$HOST2_KEY_DATA" \
  --output json)

echo -e "${GREEN}✓ Azure resources deployed${NC}"

# Extract outputs
echo -e "${YELLOW}[STEP 7/10] Extracting deployment information...${NC}"
KEY_VAULT_NAME=$(echo $DEPLOYMENT_OUTPUT | jq -r '.properties.outputs.keyVaultName.value')
APP_GW_NAME=$(echo $DEPLOYMENT_OUTPUT | jq -r '.properties.outputs.appGwName.value')
APP_GW_FQDN=$(echo $DEPLOYMENT_OUTPUT | jq -r '.properties.outputs.appGwFqdn.value')
HOST1_NAME=$(echo $DEPLOYMENT_OUTPUT | jq -r '.properties.outputs.host1Name.value')
HOST2_NAME=$(echo $DEPLOYMENT_OUTPUT | jq -r '.properties.outputs.host2Name.value')
HOST1_IP=$(echo $DEPLOYMENT_OUTPUT | jq -r '.properties.outputs.host1PrivateIp.value')
HOST2_IP=$(echo $DEPLOYMENT_OUTPUT | jq -r '.properties.outputs.host2PrivateIp.value')
JUMPBOX_NAME=$(echo $DEPLOYMENT_OUTPUT | jq -r '.properties.outputs.jumpboxName.value')
JUMPBOX_IP=$(echo $DEPLOYMENT_OUTPUT | jq -r '.properties.outputs.jumpboxPrivateIp.value')

echo -e "${GREEN}✓ Deployment information extracted${NC}"

# Get current user's Object ID for Key Vault permissions
USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

# Assign Key Vault permissions to current user
echo -e "${YELLOW}[STEP 8/10] Configuring Key Vault permissions...${NC}"
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

# Store SSH credentials in Key Vault
echo -e "${YELLOW}Storing SSH credentials in Key Vault...${NC}"
az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "vm-admin-username" \
  --value "azureuser" \
  --output none

az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "vm-ssh-private-key" \
  --file "$SSH_PRIVATE_KEY_PATH" \
  --output none

echo -e "${GREEN}✓ SSH credentials stored in Key Vault${NC}"
echo -e "  Secret: ${BLUE}vm-admin-username${NC}"
echo -e "  Secret: ${BLUE}vm-ssh-private-key${NC}"

# Store Windows jumpbox admin password in Key Vault
az keyvault secret set \
  --vault-name $KEY_VAULT_NAME \
  --name "jumpbox-admin-password" \
  --value "$JUMPBOX_ADMIN_PASSWORD" \
  --output none
echo -e "${GREEN}✓ Jumpbox admin password stored in Key Vault${NC}"
echo -e "  Secret: ${BLUE}jumpbox-admin-password${NC}"

# Deploy certificates to VMs using Azure CLI
echo -e "${YELLOW}[STEP 9/10] VMs deployed with embedded certificates${NC}"
echo -e "${GREEN}✓ Backend VMs are configured with real CA-signed certificates via cloud-init${NC}"
echo -e "${GREEN}✓ No additional certificate deployment needed${NC}"
echo ""
echo -e "${BLUE}Note: Certificates are embedded in cloud-init during VM deployment.${NC}"
echo -e "${BLUE}Backends will be healthy immediately after nginx starts (30-60 seconds).${NC}"
echo ""

# App Gateway mTLS is configured via Bicep (API 2025-03-01):
# - Two SSL profiles: 'mtls-passthrough-profile' (Passthrough) and 'mtls-strict-profile' (Strict)
# - HTTPS listener uses Passthrough; can switch to Strict via sslProfile reference
# - Rewrite rule set 'mtls-cert-forward' injects client cert headers to backend
# - Backend nginx :443 validates via headers (ssl_verify_client off) — AppGW-only access
# - Backend nginx :8443 does real mTLS (ssl_verify_client on) — direct internal access

# Install client certificates on Windows jumpbox
echo -e "${YELLOW}[STEP 10/10] Installing client certificates on Windows jumpbox ($JUMPBOX_NAME)...${NC}"

# Create client cert PFX for Windows if not already present
if [ ! -f "certs/appgw-client.pfx" ]; then
    echo -e "${BLUE}Creating client certificate PFX for Windows...${NC}"
    pushd certs > /dev/null
    openssl pkcs12 -export -out appgw-client.pfx \
      -inkey appgw-client.key \
      -in appgw-client.crt \
      -certfile ca.crt \
      -passout pass:
    popd > /dev/null
fi

CLIENT_CERT_PFX=$(base64 -w 0 certs/appgw-client.pfx)
CA_CERT_B64=$(base64 -w 0 certs/ca.crt)
CLIENT_CERT_CRT=$(base64 -w 0 certs/appgw-client.crt)
CLIENT_CERT_KEY=$(base64 -w 0 certs/appgw-client.key)

cat > /tmp/install-jumpbox-certs.ps1 << 'PWSH'
New-Item -ItemType Directory -Force -Path "C:\certs" | Out-Null
$pfxBytes = [Convert]::FromBase64String("PLACEHOLDER_PFX")
[IO.File]::WriteAllBytes("C:\certs\appgw-client.pfx", $pfxBytes)
$caBytes = [Convert]::FromBase64String("PLACEHOLDER_CA")
[IO.File]::WriteAllBytes("C:\certs\ca.crt", $caBytes)
$crtBytes = [Convert]::FromBase64String("PLACEHOLDER_CRT")
[IO.File]::WriteAllBytes("C:\certs\appgw-client.crt", $crtBytes)
$keyBytes = [Convert]::FromBase64String("PLACEHOLDER_KEY")
[IO.File]::WriteAllBytes("C:\certs\appgw-client.key", $keyBytes)
$pfxPass = ConvertTo-SecureString -String "" -AsPlainText -Force
Import-PfxCertificate -FilePath "C:\certs\appgw-client.pfx" -CertStoreLocation "Cert:\LocalMachine\My" -Password $pfxPass | Out-Null
Import-Certificate -FilePath "C:\certs\ca.crt" -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null
Write-Host "Certificates installed successfully."
Write-Host "  Client cert PFX : C:\certs\appgw-client.pfx  (also in Cert:\LocalMachine\My)"
Write-Host "  CA cert          : C:\certs\ca.crt             (also in Cert:\LocalMachine\Root)"
Write-Host "  Client cert PEM  : C:\certs\appgw-client.crt"
Write-Host "  Client key PEM   : C:\certs\appgw-client.key"
PWSH

sed -i "s|PLACEHOLDER_PFX|$CLIENT_CERT_PFX|" /tmp/install-jumpbox-certs.ps1
sed -i "s|PLACEHOLDER_CA|$CA_CERT_B64|" /tmp/install-jumpbox-certs.ps1
sed -i "s|PLACEHOLDER_CRT|$CLIENT_CERT_CRT|" /tmp/install-jumpbox-certs.ps1
sed -i "s|PLACEHOLDER_KEY|$CLIENT_CERT_KEY|" /tmp/install-jumpbox-certs.ps1

az vm run-command invoke \
  --resource-group $RESOURCE_GROUP \
  --name $JUMPBOX_NAME \
  --command-id RunPowerShellScript \
  --scripts "$(cat /tmp/install-jumpbox-certs.ps1)" \
  --output none

echo -e "${GREEN}✓ Client certificates installed on Windows jumpbox${NC}"
echo -e "  Cert files     : ${BLUE}C:\\certs\\${NC}"
echo -e "  Client cert    : ${BLUE}Cert:\\LocalMachine\\My${NC}"
echo -e "  CA cert        : ${BLUE}Cert:\\LocalMachine\\Root${NC}"

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
echo -e "  🖥️  Jumpbox:      $JUMPBOX_NAME ($JUMPBOX_IP)"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Wait a few minutes for all services to fully start"
echo ""
echo -e "${YELLOW}Path 1 — Via Application Gateway (port 443, header-based mTLS):${NC}"
echo "2. Test without client cert (should get 403 from backend):"
echo -e "   ${GREEN}curl -k https://$APP_GW_FQDN${NC}"
echo "3. Test with client cert (full mTLS via AppGW Passthrough):"
echo -e "   ${GREEN}curl --cert certs/appgw-client.crt --key certs/appgw-client.key --cacert certs/ca.crt https://$APP_GW_FQDN${NC}"
echo "4. Check forwarded certificate headers via /whoami:"
echo -e "   ${GREEN}curl --cert certs/appgw-client.crt --key certs/appgw-client.key --cacert certs/ca.crt https://$APP_GW_FQDN/whoami${NC}"
echo ""
echo -e "${YELLOW}Path 2 — Direct internal mTLS (port 8443, real TLS handshake):${NC}"
echo "5. From jumpbox, test direct mTLS to backend (nginx prompts for client cert):"
echo -e "   ${GREEN}curl --cert C:\\certs\\appgw-client.crt --key C:\\certs\\appgw-client.key --cacert C:\\certs\\ca.crt https://<backend-ip>:8443${NC}"
echo "6. Check native nginx mTLS variables via /whoami:"
echo -e "   ${GREEN}curl --cert C:\\certs\\appgw-client.crt --key C:\\certs\\appgw-client.key --cacert C:\\certs\\ca.crt https://<backend-ip>:8443/whoami${NC}"
echo ""
echo -e "${YELLOW}Accessing Windows Jumpbox via Azure Bastion (RDP):${NC}"
echo "  Retrieve jumpbox admin password:"
echo -e "   ${GREEN}az keyvault secret show --vault-name $KEY_VAULT_NAME --name jumpbox-admin-password --query value -o tsv${NC}"
echo "  Username: jumpboxadmin"
echo "  Client certs pre-installed in C:\\certs\\ and Windows certificate store"
echo ""
echo -e "${YELLOW}Accessing VMs via Azure Bastion (SSH credentials from Key Vault):${NC}"
echo "  Retrieve the SSH private key:"
echo -e "   ${GREEN}az keyvault secret show --vault-name $KEY_VAULT_NAME --name vm-ssh-private-key --query value -o tsv > ~/.ssh/lab-vm-key && chmod 600 ~/.ssh/lab-vm-key${NC}"
echo "  Retrieve the admin username:"
echo -e "   ${GREEN}az keyvault secret show --vault-name $KEY_VAULT_NAME --name vm-admin-username --query value -o tsv${NC}"
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
  "jumpbox": {
    "name": "$JUMPBOX_NAME",
    "privateIp": "$JUMPBOX_IP",
    "adminUsername": "jumpboxadmin",
    "kvSecretPassword": "jumpbox-admin-password",
    "certsDirectory": "C:\\certs"
  },
  "sshCredentials": {
    "kvSecretUsername": "vm-admin-username",
    "kvSecretPrivateKey": "vm-ssh-private-key",
    "retrieveCommand": "az keyvault secret show --vault-name $KEY_VAULT_NAME --name vm-ssh-private-key --query value -o tsv > ~/.ssh/lab-vm-key && chmod 600 ~/.ssh/lab-vm-key"
  },
  "deploymentDate": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo -e "${GREEN}Deployment information saved to deployment-info.json${NC}"
echo ""
