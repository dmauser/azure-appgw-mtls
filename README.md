# Azure mTLS Lab with Application Gateway and Nginx Backends

![Azure](https://img.shields.io/badge/Azure-0078D4?style=for-the-badge&logo=microsoft-azure&logoColor=white)
![Bicep](https://img.shields.io/badge/Bicep-0078D4?style=for-the-badge&logo=microsoft-azure&logoColor=white)
![Nginx](https://img.shields.io/badge/Nginx-009639?style=for-the-badge&logo=nginx&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black)

A complete, production-ready Azure networking lab demonstrating **Mutual TLS (mTLS)** authentication between Azure Application Gateway and backend Linux VMs running Nginx. This lab features automated certificate generation, infrastructure-as-code deployment using Bicep, and color-coded backend servers for easy visual verification.

## 📑 Table of Contents

- [Overview](#-overview)
- [Architecture](#️-architecture)
- [Features](#-features)
- [Prerequisites](#-prerequisites)
- [Quick Start](#-quick-start)
- [Testing the Deployment](#-testing-the-deployment)
- [Manual mTLS Configuration (Advanced)](#-manual-mtls-configuration-advanced)
- [Project Structure](#-project-structure)
- [Certificate Details](#-certificate-details)
- [Troubleshooting](#️-troubleshooting)
- [Estimated Cost](#-estimated-cost)
- [Cleanup](#-cleanup)
- [Learning Objectives](#-learning-objectives)
- [Contributing](#-contributing)
- [License](#-license)
- [Acknowledgments](#-acknowledgments)
- [Contact](#-contact)
- [Related Resources](#-related-resources)

---

## 🎯 Overview

This lab creates a fully automated Azure environment that demonstrates:
- **Mutual TLS (mTLS)** authentication between Application Gateway and backend servers
- **Self-signed certificate** generation and management
- **Azure Key Vault** integration for secure certificate storage
- **Infrastructure as Code** using Azure Bicep
- **Cloud-init** automated VM configuration
- **Azure Bastion** for secure VM access

## 🏗️ Architecture

```
                                    Internet
                                       │
                                       ▼
                         ┌─────────────────────────┐
                         │  Application Gateway    │
                         │   (Public Endpoint)     │
                         │  - HTTPS Listener       │
                         │  - Client Certificate   │
                         └──────────┬──────────────┘
                                    │
                                    │ mTLS
                                    │
          ┌─────────────────────────┼─────────────────────────┐
          │                         │                         │
          ▼                         ▼                         ▼
    ┌──────────┐            ┌──────────┐              ┌──────────┐
    │  Host1   │            │  Host2   │              │  Bastion │
    │  (RED)   │            │  (BLUE)  │              │          │
    │  Nginx   │            │  Nginx   │              └──────────┘
    │  :443    │            │  :443    │
    │ + Server │            │ + Server │
    │   Cert   │            │   Cert   │
    │ + CA Cert│            │ + CA Cert│
    └──────────┘            └──────────┘
          │                         │
          └─────────────────────────┘
                      │
                      ▼
              ┌───────────────┐
              │  Key Vault    │
              │ (Certificates)│
              └───────────────┘
```

## ✨ Features

- 🔐 **Mutual TLS Authentication**: Full mTLS implementation between Application Gateway and backends
- 🎨 **Color-Coded Backends**: Red (Host1) and Blue (Host2) for easy visual verification
- 🤖 **Fully Automated**: Single command deployment using bash scripts
- 🔑 **Certificate Management**: Automated generation and distribution of certificates
- 🏰 **Secure Architecture**: Azure Bastion for VM access, NSG rules, private subnets
- 📊 **Production Ready**: Follows Azure best practices for networking and security
- 🔄 **Idempotent Deployment**: Safe to re-run deployment scripts
- 📝 **Infrastructure as Code**: Complete Bicep templates for reproducibility

## 📋 Prerequisites

Before deploying this lab, ensure you have:

### Required Tools

1. **Azure CLI** (version 2.50.0 or later)
   - Install: [https://docs.microsoft.com/en-us/cli/azure/install-azure-cli](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
   - Verify: `az --version`

2. **OpenSSL** (for certificate generation)
   - Linux/macOS: Usually pre-installed
   - Windows: Install via WSL or Git Bash
   - Verify: `openssl version`

3. **jq** (JSON processor)
   - Linux: `sudo apt-get install jq`
   - macOS: `brew install jq`
   - Windows WSL: `sudo apt-get install jq`
   - Verify: `jq --version`

4. **Bash Shell**
   - Linux/macOS: Built-in terminal
   - Windows: Use WSL2 or Git Bash

### Azure Requirements

- **Active Azure Subscription** with:
  - Permission to create resources
  - Sufficient quota for:
    - 2x Standard_B2s VMs
    - 1x Application Gateway v2
    - 1x Azure Bastion (Basic tier)
    - 1x Key Vault
  - Owner or Contributor role on the subscription or resource group

### SSH Key

- SSH key pair for VM authentication
  - The deployment script will generate one if not present at `~/.ssh/id_rsa.pub`
  - Or provide your own public key

## 🚀 Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/dmauser/azure-appgw-mtls.git
cd azure-appgw-mtls
```

### 2. Login to Azure

```bash
az login
az account set --subscription "Your-Subscription-Name-or-ID"
```

### 3. Deploy the Lab

```bash
chmod +x deploy.sh generateCerts.sh
./deploy.sh
```

The deployment will:
1. ✅ Check prerequisites
2. ✅ Generate certificates (Root CA, Server certs, Client cert)
3. ✅ Generate a lab-dedicated SSH key pair and store it in Key Vault
4. ✅ Create Azure Resource Group
5. ✅ Deploy infrastructure (VNet, VMs, Application Gateway, Bastion, Key Vault)
6. ✅ Upload certificates to Key Vault
7. ✅ Store VM SSH credentials (username + private key) in Key Vault
8. ✅ Configure backend servers with certificates
9. ✅ Display deployment information

**Deployment time**: ~15-20 minutes

## 🧪 Testing the Deployment

### 1. Basic Connectivity Test

After deployment completes, get your Application Gateway FQDN from the output or run:

```bash
source deployment-info.json
APP_GW_FQDN=$(jq -r '.appGatewayFqdn' deployment-info.json)
echo "Application Gateway: http://$APP_GW_FQDN"
```

Test HTTP access (initial configuration):

```bash
curl http://$APP_GW_FQDN
```

You should see either the RED (Host1) or BLUE (Host2) page.

### 2. Retrieve VM SSH Credentials from Key Vault

SSH credentials for both backend VMs are stored securely in Azure Key Vault. To connect via Azure Bastion, first retrieve them:

```bash
# Get the Key Vault name from the deployment output
KEY_VAULT_NAME=$(jq -r '.keyVaultName' deployment-info.json)

# Retrieve the admin username
ADMIN_USER=$(az keyvault secret show \
  --vault-name $KEY_VAULT_NAME \
  --name vm-admin-username \
  --query value -o tsv)
echo "Admin username: $ADMIN_USER"

# Download the SSH private key
az keyvault secret show \
  --vault-name $KEY_VAULT_NAME \
  --name vm-ssh-private-key \
  --query value -o tsv > ~/.ssh/lab-vm-key
chmod 600 ~/.ssh/lab-vm-key
echo "SSH private key saved to ~/.ssh/lab-vm-key"
```

Then connect to a VM via Azure Bastion using the retrieved key and username.

### 4. Verify Backend Certificates

Connect to VMs via Azure Bastion and verify nginx is running with certificates:

```bash
# Get VM names from deployment
RESOURCE_GROUP="rg-mtls-lab"
HOST1=$(az vm list -g $RESOURCE_GROUP --query "[?contains(name, 'host1')].name" -o tsv)

# Check nginx status via run-command
az vm run-command invoke   --resource-group $RESOURCE_GROUP   --name $HOST1   --command-id RunShellScript   --scripts "sudo systemctl status nginx"   --query 'value[0].message' -o tsv
```

### 5. Test Direct Backend Access (via Bastion)

Use Azure Bastion to connect to a VM and test local nginx:

```bash
# On the VM (via Bastion)
curl -k https://localhost
# Should display the colored page with mTLS indicator
```

### 6. Verify mTLS Configuration

Check that the backend requires client certificates:

```bash
# This should fail without client certificate
curl -k https://<backend-private-ip>

# This should succeed with proper client certificate
curl --cert certs/appgw-client.crt      --key certs/appgw-client.key      --cacert certs/ca.crt      -k https://<backend-private-ip>
```

## 🔧 Manual mTLS Configuration (Advanced)

The initial deployment sets up Application Gateway in HTTP mode. To enable full HTTPS with mTLS:

### Option 1: Use Azure Portal

1. Navigate to Application Gateway → Settings → Listeners
2. Add new HTTPS listener:
   - Port: 443
   - Protocol: HTTPS
   - Choose certificate from Key Vault: `appgw-ssl-cert`
3. Update Backend HTTP Settings:
   - Protocol: HTTPS
   - Use well-known CA certificate: No
   - Upload CA certificate: Upload `certs/ca.crt`
   - Enable certificate verification
4. Update routing rules to use HTTPS listener

### Option 2: Use Azure CLI (Coming Soon)

A `configure-mtls.sh` script for automated mTLS configuration will be added in future updates.

## 📁 Project Structure

```
azure-appgw-mtls/
├── main.bicep                 # Main Bicep template
├── cloud-init-host1.yaml      # Cloud-init for Host1 (Red)
├── cloud-init-host2.yaml      # Cloud-init for Host2 (Blue)
├── generateCerts.sh           # Certificate generation script
├── deploy.sh                  # Main deployment orchestration script
├── README.md                  # This file
├── .gitignore                 # Git ignore rules
└── certs/                     # Generated certificates (not in git)
    ├── ca.crt                 # Root CA certificate
    ├── ca.key                 # Root CA private key
    ├── host1.crt              # Host1 server certificate
    ├── host1.key              # Host1 private key
    ├── host2.crt              # Host2 server certificate
    ├── host2.key              # Host2 private key
    ├── appgw-client.crt       # App Gateway client certificate
    ├── appgw-client.key       # App Gateway client key
    ├── appgw-ssl.pfx          # PFX bundle for App Gateway
    ├── vm-ssh-key             # Lab VM SSH private key (stored in Key Vault)
    └── vm-ssh-key.pub         # Lab VM SSH public key
```

## 🔐 Certificate Details

### Certificate Hierarchy

```
Root CA (self-signed)
├── Host1 Server Certificate (server auth)
├── Host2 Server Certificate (server auth)
└── Application Gateway Client Certificate (client auth)
```

### Certificate Validity

- **Root CA**: 10 years (3650 days)
- **Server Certificates**: 825 days (Apple/Browser compatibility)
- **Client Certificate**: 825 days

### Certificate Files

| File | Purpose | Location |
|------|---------|----------|
| `ca.crt` | Root CA certificate | Key Vault + Backend VMs |
| `host1.crt/key` | Host1 server certificate | Host1 VM `/etc/nginx/ssl/` |
| `host2.crt/key` | Host2 server certificate | Host2 VM `/etc/nginx/ssl/` |
| `appgw-client.crt/key` | Client authentication | Application Gateway |
| `appgw-ssl.pfx` | PFX bundle | Key Vault |

## 🛠️ Troubleshooting

### Issue: Deployment Fails at Certificate Upload

**Symptom**: Error uploading certificates to Key Vault

**Solution**:
```bash
# Verify Key Vault permissions
az role assignment list   --scope /subscriptions/<sub-id>/resourceGroups/rg-mtls-lab/providers/Microsoft.KeyVault/vaults/<vault-name>

# Manually assign Key Vault Administrator role
az role assignment create   --role "Key Vault Administrator"   --assignee $(az ad signed-in-user show --query id -o tsv)   --scope <key-vault-resource-id>
```

### Issue: Nginx Not Starting on VMs

**Symptom**: curl to backend returns connection refused

**Solution**:
```bash
# Check nginx status
az vm run-command invoke   --resource-group rg-mtls-lab   --name <vm-name>   --command-id RunShellScript   --scripts "sudo systemctl status nginx; sudo journalctl -u nginx -n 50"

# Restart nginx
az vm run-command invoke   --resource-group rg-mtls-lab   --name <vm-name>   --command-id RunShellScript   --scripts "sudo systemctl restart nginx"
```

### Issue: Application Gateway Returns 502

**Symptom**: Application Gateway shows unhealthy backends

**Possible Causes**:
1. Backend certificates not deployed correctly
2. NSG blocking traffic
3. Nginx not listening on 443

**Solution**:
```bash
# Check Application Gateway backend health
az network application-gateway show-backend-health   --resource-group rg-mtls-lab   --name <appgw-name>

# Verify NSG rules
az network nsg rule list   --resource-group rg-mtls-lab   --nsg-name nsg-backend-*

# Redeploy certificates to VMs
./deploy.sh  # Script is idempotent
```

### Issue: Certificate Errors

**Symptom**: SSL handshake failures

**Solution**:
```bash
# Verify certificate on backend
az vm run-command invoke   --resource-group rg-mtls-lab   --name <vm-name>   --command-id RunShellScript   --scripts "sudo openssl s_client -connect localhost:443 -cert /etc/nginx/ssl/server.crt"

# Regenerate certificates
rm -rf certs/
./generateCerts.sh
./deploy.sh
```

## 💰 Estimated Cost

This lab deploys several Azure resources that incur costs while running. The estimates below are approximate and based on **East US** pricing as of early 2026. Actual costs vary by region and subscription type.

| Resource | SKU / Tier | Est. Cost/Hour | Est. Cost/Day |
|---|---|---|---|
| Application Gateway v2 | Standard_v2 (1 CU) | ~$0.246 | ~$5.90 |
| Azure Bastion | Basic | ~$0.19 | ~$4.56 |
| VM - Host1 | Standard_B2s | ~$0.042 | ~$1.01 |
| VM - Host2 | Standard_B2s | ~$0.042 | ~$1.01 |
| Azure Key Vault | Standard | ~$0.00 | ~$0.03 |
| Public IPs (x2) | Standard | ~$0.008 | ~$0.19 |
| Managed Disks (x2) | Standard SSD (32 GB) | ~$0.004 | ~$0.10 |
| **Total (approx.)** | | **~$0.53** | **~$12.80** |

> **Note**: Application Gateway v2 has a fixed hourly charge plus a per-capacity-unit charge. The estimate above assumes minimal traffic (1 capacity unit). Under load, the Application Gateway cost can increase significantly.

### Cost-Saving Tips

- 🛑 **Delete the lab when not in use** — the biggest savings come from deleting resources entirely (see [Cleanup](#-cleanup) below)
- ⏸️ **Deallocate VMs** when not testing backends — stops VM compute charges while preserving disks
- 🏰 **Bastion is the costliest "always-on" component** after App Gateway — consider deleting it and re-deploying when needed for VM access
- 🔑 **Key Vault** charges are negligible (charged per 10,000 operations), so it has minimal cost impact

---

## 🧹 Cleanup

To delete all resources and avoid Azure charges:

```bash
# Delete resource group (removes all resources)
az group delete --name rg-mtls-lab --yes --no-wait

# Remove local certificates (optional)
rm -rf certs/
rm deployment-info.json
```

**Note**: The resource group deletion will remove:
- Virtual Network and all subnets
- Virtual Machines
- Application Gateway
- Azure Bastion
- Key Vault (soft-delete enabled, recoverable for 7 days)
- All associated resources (NICs, NSGs, Public IPs, Disks)

## 💡 Learning Objectives

After completing this lab, you will understand:

1. **Mutual TLS (mTLS)** concepts and implementation
2. **Azure Application Gateway** configuration for HTTPS and mTLS
3. **Certificate management** in Azure Key Vault
4. **Azure Bicep** for Infrastructure as Code
5. **Cloud-init** for automated VM configuration
6. **Azure networking** best practices
7. **Nginx** SSL/TLS configuration
8. **OpenSSL** certificate generation and management

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes:

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 📝 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🙏 Acknowledgments

- Built for Azure networking enthusiasts and learners
- Inspired by real-world mTLS implementation patterns
- Designed for the Azure community

## 📧 Contact

**Author**: Daniel Mauser

- GitHub: [@dmauser](https://github.com/dmauser)
- LinkedIn: [Daniel Mauser](https://www.linkedin.com/in/danmauser/)

## 🔗 Related Resources

- [Azure Application Gateway Documentation](https://docs.microsoft.com/en-us/azure/application-gateway/)
- [Mutual TLS Overview](https://docs.microsoft.com/en-us/azure/application-gateway/mutual-authentication-overview)
- [Azure Bicep Documentation](https://docs.microsoft.com/en-us/azure/azure-resource-manager/bicep/)
- [Nginx SSL/TLS Configuration](https://nginx.org/en/docs/http/configuring_https_servers.html)
- [Azure Key Vault Best Practices](https://docs.microsoft.com/en-us/azure/key-vault/general/best-practices)

---

⭐ **If you found this lab helpful, please give it a star!** ⭐
