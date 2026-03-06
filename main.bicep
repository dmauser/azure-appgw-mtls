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

// Variables
var vnetName = 'vnet-mtls-${uniqueSuffix}'
var appGwSubnetName = 'snet-appgw'
var backendSubnetName = 'snet-backend'
var bastionSubnetName = 'AzureBastionSubnet'
var appGwName = 'appgw-mtls-${uniqueSuffix}'
var appGwPublicIpName = 'pip-appgw-${uniqueSuffix}'
var bastionName = 'bastion-mtls-${uniqueSuffix}'
var bastionPublicIpName = 'pip-bastion-${uniqueSuffix}'
var nsgBackendName = 'nsg-backend-${uniqueSuffix}'
var keyVaultName = 'kv-mtls-${uniqueSuffix}'
var host1Name = 'vm-host1-${uniqueSuffix}'
var host2Name = 'vm-host2-${uniqueSuffix}'

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

// Application Gateway (will be configured post-deployment with certificates)
resource applicationGateway 'Microsoft.Network/applicationGateways@2023-05-01' = {
  name: appGwName
  location: location
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
    ]
    probes: [
      {
        name: 'health-probe'
        properties: {
          protocol: 'Https'
          path: '/'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: false
          host: 'backend.azure.local'
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
