// Azure mTLS Lab - Main Bicep Template
// This template deploys a complete environment demonstrating mTLS between Application Gateway and backend VMs

@description('Location for all resources')
param location string = resourceGroup().location

@description('Administrator username for VMs')
param adminUsername string = 'azureuser'

@description('SSH public key for VM authentication')
@secure()
param sshPublicKey string

@description('Unique suffix for resource naming')
param uniqueSuffix string = uniqueString(resourceGroup().id)

@description('Virtual Network address prefix')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Application Gateway subnet prefix')
param appGwSubnetPrefix string = '10.0.1.0/24'

@description('Backend VMs subnet prefix')
param backendSubnetPrefix string = '10.0.2.0/24'

@description('Bastion subnet prefix')
param bastionSubnetPrefix string = '10.0.3.0/24'

@description('Base64-encoded CA certificate for App Gateway to trust backend server certificates')
param caCertData string

@description('Base64-encoded PFX certificate for Application Gateway HTTPS listener (frontend SSL termination)')
@secure()
param appGwSslCertData string

@description('Password for the Application Gateway SSL PFX certificate (empty string if none)')
@secure()
param appGwSslCertPassword string = ''

@description('Windows jumpbox VM administrator username')
param jumpboxAdminUsername string = 'jumpboxadmin'

@description('Windows jumpbox VM administrator password')
@secure()
param jumpboxAdminPassword string

@description('Jumpbox subnet prefix')
param jumpboxSubnetPrefix string = '10.0.4.0/24'

// Variables
var vnetName = 'vnet-mtls-${uniqueSuffix}'
var appGwSubnetName = 'snet-appgw'
var backendSubnetName = 'snet-backend'
var bastionSubnetName = 'AzureBastionSubnet'
var jumpboxSubnetName = 'snet-jumpbox'
var appGwName = 'appgw-mtls-${uniqueSuffix}'
var appGwPublicIpName = 'pip-appgw-${uniqueSuffix}'
var bastionName = 'bastion-mtls-${uniqueSuffix}'
var bastionPublicIpName = 'pip-bastion-${uniqueSuffix}'
var nsgBackendName = 'nsg-backend-${uniqueSuffix}'
var nsgJumpboxName = 'nsg-jumpbox-${uniqueSuffix}'
var keyVaultName = 'kv-mtls-${uniqueSuffix}'
var host1Name = 'vm-host1-${uniqueSuffix}'
var host2Name = 'vm-host2-${uniqueSuffix}'
var jumpboxName = 'vm-jumpbox-${uniqueSuffix}'
var appGwIdentityName = 'id-appgw-${uniqueSuffix}'

// Virtual Network
resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: appGwSubnetName
        properties: {
          addressPrefix: appGwSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Disabled'
        }
      }
      {
        name: backendSubnetName
        properties: {
          addressPrefix: backendSubnetPrefix
          networkSecurityGroup: {
            id: nsgBackend.id
          }
        }
      }
      {
        name: bastionSubnetName
        properties: {
          addressPrefix: bastionSubnetPrefix
        }
      }
      {
        name: jumpboxSubnetName
        properties: {
          addressPrefix: jumpboxSubnetPrefix
          networkSecurityGroup: {
            id: nsgJumpbox.id
          }
        }
      }
    ]
  }
}

// Network Security Group for Backend VMs
resource nsgBackend 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: nsgBackendName
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-HTTPS-AppGw'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: appGwSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'Allow-SSH-Bastion'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'Allow-HTTPS-Jumpbox'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: jumpboxSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// Network Security Group for Jumpbox
resource nsgJumpbox 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: nsgJumpboxName
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-RDP-Bastion'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// Key Vault for storing certificates
resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enabledForDeployment: true
    enabledForTemplateDeployment: true
    enabledForDiskEncryption: false
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

// Public IP for Application Gateway
resource appGwPublicIp 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: appGwPublicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: 'appgw-mtls-${uniqueSuffix}'
    }
  }
}

// Public IP for Bastion
resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: bastionPublicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// Azure Bastion
resource bastion 'Microsoft.Network/bastionHosts@2023-05-01' = {
  name: bastionName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'bastionIpConfig'
        properties: {
          subnet: {
            id: '${vnet.id}/subnets/${bastionSubnetName}'
          }
          publicIPAddress: {
            id: bastionPublicIp.id
          }
        }
      }
    ]
  }
}

// Network Interfaces for Host1
resource nic1 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: 'nic-${host1Name}'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: '${vnet.id}/subnets/${backendSubnetName}'
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

// Network Interfaces for Host2
resource nic2 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: 'nic-${host2Name}'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: '${vnet.id}/subnets/${backendSubnetName}'
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

// Network Interface for Jumpbox
resource nicJumpbox 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: 'nic-${jumpboxName}'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: '${vnet.id}/subnets/${jumpboxSubnetName}'
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

// Cloud-init configuration for Host1 (Red)
var cloudInitHost1 = base64(loadTextContent('cloud-init-host1.yaml'))

// Cloud-init configuration for Host2 (Blue)
var cloudInitHost2 = base64(loadTextContent('cloud-init-host2.yaml'))

// Virtual Machine - Host1 (Red)
resource vmHost1 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: host1Name
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2s'
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: 'host1'
      adminUsername: adminUsername
      customData: cloudInitHost1
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic1.id
        }
      ]
    }
  }
}

// Virtual Machine - Host2 (Blue)
resource vmHost2 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: host2Name
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2s'
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: 'host2'
      adminUsername: adminUsername
      customData: cloudInitHost2
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic2.id
        }
      ]
    }
  }
}

// Virtual Machine - Jumpbox (Windows)
resource vmJumpbox 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: jumpboxName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2ms'
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: 'jumpbox'
      adminUsername: jumpboxAdminUsername
      adminPassword: jumpboxAdminPassword
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nicJumpbox.id
        }
      ]
    }
  }
}

// User-assigned managed identity for App Gateway (SystemAssigned is not supported on this resource type)
resource appGwIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: appGwIdentityName
  location: location
}

// Application Gateway
resource applicationGateway 'Microsoft.Network/applicationGateways@2025-03-01' = {
  name: appGwName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${appGwIdentity.id}': {}
    }
  }
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
      capacity: 2
    }
    gatewayIPConfigurations: [
      {
        name: 'appGwIpConfig'
        properties: {
          subnet: {
            id: '${vnet.id}/subnets/${appGwSubnetName}'
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appGwFrontendIp'
        properties: {
          publicIPAddress: {
            id: appGwPublicIp.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port-443'
        properties: {
          port: 443
        }
      }
      {
        name: 'port-80'
        properties: {
          port: 80
        }
      }
    ]
    // Use a modern predefined TLS policy (required for mTLS Passthrough with API 2025-03-01)
    sslPolicy: {
      policyType: 'Predefined'
      policyName: 'AppGwSslPolicy20220101'
    }
    // Frontend SSL certificate for the HTTPS listener (terminates TLS from incoming clients)
    sslCertificates: [
      {
        name: 'appgw-ssl-cert'
        properties: {
          data: appGwSslCertData
          password: appGwSslCertPassword
        }
      }
    ]
    // mTLS Passthrough SSL profile: gateway requests a client cert but does NOT validate it.
    // Certificate validation and policy enforcement are delegated to the backend servers.
    sslProfiles: [
      {
        name: 'mtls-passthrough-profile'
        properties: {
          clientAuthConfiguration: {
            verifyClientCertIssuerDN: false
            verifyClientRevocation: 'None'
            verifyClientAuthMode: 'Passthrough'
          }
        }
      }
    ]
    trustedRootCertificates: [
      {
        name: 'backend-ca-cert'
        properties: {
          data: caCertData
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'backend-pool'
        properties: {
          backendAddresses: [
            {
              ipAddress: nic1.properties.ipConfigurations[0].properties.privateIPAddress
            }
            {
              ipAddress: nic2.properties.ipConfigurations[0].properties.privateIPAddress
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'https-settings'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
          pickHostNameFromBackendAddress: false
          trustedRootCertificates: [
            {
              id: resourceId('Microsoft.Network/applicationGateways/trustedRootCertificates', appGwName, 'backend-ca-cert')
            }
          ]
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', appGwName, 'health-probe')
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'http-listener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGwName, 'appGwFrontendIp')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, 'port-80')
          }
          protocol: 'Http'
        }
      }
      // HTTPS listener with mTLS Passthrough SSL profile
      {
        name: 'https-listener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGwName, 'appGwFrontendIp')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, 'port-443')
          }
          protocol: 'Https'
          sslCertificate: {
            id: resourceId('Microsoft.Network/applicationGateways/sslCertificates', appGwName, 'appgw-ssl-cert')
          }
          sslProfile: {
            id: resourceId('Microsoft.Network/applicationGateways/sslProfiles', appGwName, 'mtls-passthrough-profile')
          }
        }
      }
    ]
    // Rewrite rule set: inject the client certificate (PEM) as an HTTP header to the backend.
    // App Gateway captures the certificate from the mTLS handshake via the
    // 'client_certificate' mutual-authentication server variable (works with Passthrough mode).
    rewriteRuleSets: [
      {
        name: 'mtls-cert-forward'
        properties: {
          rewriteRules: [
            {
              name: 'forward-client-cert'
              ruleSequence: 100
              actionSet: {
                requestHeaderConfigurations: [
                  {
                    headerName: 'X-Client-Cert'
                    headerValue: '{var_client_certificate}'
                  }
                ]
              }
            }
          ]
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'routing-rule-http'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'http-listener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGwName, 'backend-pool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', appGwName, 'https-settings')
          }
        }
      }
      // HTTPS routing rule (priority 90 = evaluated before HTTP rule)
      // References the rewrite rule set that forwards the client certificate header
      {
        name: 'routing-rule-https'
        properties: {
          ruleType: 'Basic'
          priority: 90
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'https-listener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGwName, 'backend-pool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', appGwName, 'https-settings')
          }
          rewriteRuleSet: {
            id: resourceId('Microsoft.Network/applicationGateways/rewriteRuleSets', appGwName, 'mtls-cert-forward')
          }
        }
      }
    ]
    probes: [
      {
        name: 'health-probe'
        properties: {
          protocol: 'Https'
          path: '/health'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: false
          host: 'backend.contoso.com'
          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ]
  }
  dependsOn: [
    vmHost1
    vmHost2
  ]
}

// Grant App Gateway managed identity access to read Key Vault secrets (needed for KV-referenced SSL certs)
var kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
resource appGwKvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, appGwIdentity.id, kvSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: appGwIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Outputs
output resourceGroupName string = resourceGroup().name
output location string = location
output vnetName string = vnet.name
output keyVaultName string = keyVault.name
output keyVaultId string = keyVault.id
output appGwName string = applicationGateway.name
output appGwPublicIp string = appGwPublicIp.properties.ipAddress
output appGwFqdn string = appGwPublicIp.properties.dnsSettings.fqdn
output host1Name string = vmHost1.name
output host2Name string = vmHost2.name
output host1PrivateIp string = nic1.properties.ipConfigurations[0].properties.privateIPAddress
output host2PrivateIp string = nic2.properties.ipConfigurations[0].properties.privateIPAddress
output bastionName string = bastion.name
output appGwIdentityPrincipalId string = appGwIdentity.properties.principalId
output jumpboxName string = vmJumpbox.name
output jumpboxPrivateIp string = nicJumpbox.properties.ipConfigurations[0].properties.privateIPAddress
