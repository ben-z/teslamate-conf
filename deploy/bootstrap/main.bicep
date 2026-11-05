targetScope = 'resourceGroup'

param aksName string = 'unicorns-aks'
param aksOidcIssuerUrl string
param githubRepository string = 'ben-z/teslamate-conf'
param githubEnvironment string = 'production'
param kubernetesNamespace string = 'teslamate'
param kubernetesServiceAccount string = 'teslamate'
param operatorObjectId string

@minLength(3)
@maxLength(24)
param keyVaultName string = 'teslamate${uniqueString(subscription().id, resourceGroup().id)}'

param location string = resourceGroup().location

var deployerIdentityName = 'teslamate-deployer'
var secretIdentityName = 'teslamate-secrets'
var clusterUserRoleId = '4abbcc35-e782-43d8-92c5-2d3f1bd2253f'
var keyVaultSecretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource aks 'Microsoft.ContainerService/managedClusters@2024-10-01' existing = {
  name: aksName
}

resource deployerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: deployerIdentityName
  location: location
}

resource deployerFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: deployerIdentity
  name: 'github-production'
  properties: {
    audiences: [
      'api://AzureADTokenExchange'
    ]
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:${githubRepository}:environment:${githubEnvironment}'
  }
}

resource clusterUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: subscription()
  name: clusterUserRoleId
}

resource deployerClusterUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aks.id, deployerIdentity.id, clusterUserRoleId)
  scope: aks
  properties: {
    principalId: deployerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: clusterUserRole.id
  }
}

resource secretIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: secretIdentityName
  location: location
}

resource secretFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: secretIdentity
  name: 'aks-workload'
  properties: {
    audiences: [
      'api://AzureADTokenExchange'
    ]
    issuer: aksOidcIssuerUrl
    subject: 'system:serviceaccount:${kubernetesNamespace}:${kubernetesServiceAccount}'
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    enablePurgeProtection: true
    enableRbacAuthorization: true
    enableSoftDelete: true
    publicNetworkAccess: 'Enabled'
    softDeleteRetentionInDays: 7
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
  }
}

resource keyVaultSecretsUserRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: subscription()
  name: keyVaultSecretsUserRoleId
}

resource secretIdentityVaultAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, secretIdentity.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    principalId: secretIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultSecretsUserRole.id
  }
}

resource keyVaultSecretsOfficerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: subscription()
  name: keyVaultSecretsOfficerRoleId
}

resource operatorVaultAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, operatorObjectId, keyVaultSecretsOfficerRoleId)
  scope: keyVault
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: keyVaultSecretsOfficerRole.id
  }
}

output deployerClientId string = deployerIdentity.properties.clientId
output deployerPrincipalId string = deployerIdentity.properties.principalId
output keyVaultName string = keyVault.name
output secretIdentityClientId string = secretIdentity.properties.clientId

@maxLength(24)
param backupAccountName string = 'tmbackup${uniqueString(subscription().id, resourceGroup().id)}'

resource backupAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: backupAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource backupBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: backupAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 14
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 14
    }
  }
}

resource backupContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: backupBlobService
  name: 'teslamate'
  properties: {
    publicAccess: 'None'
  }
}

resource backupRetention 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: backupAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'expire-database-backups'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: ['blockBlob']
              prefixMatch: ['teslamate/']
            }
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: 30
                }
              }
            }
          }
        }
      ]
    }
  }
}

var blobContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var blobReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

resource backupWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(backupContainer.id, secretIdentity.id, blobContributorRoleId)
  scope: backupContainer
  properties: {
    principalId: secretIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobContributorRoleId)
  }
}

resource backupReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(backupContainer.id, operatorObjectId, blobReaderRoleId)
  scope: backupContainer
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobReaderRoleId)
  }
}

output backupAccountName string = backupAccount.name
