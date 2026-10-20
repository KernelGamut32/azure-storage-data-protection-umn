// =============================================================================
// Session 3 lab solution, part 2: immutable Backup vault with multi-user
// authorization, plus the storage account it will protect with vaulted blob
// backup. Scope: the attendee's lab resource group.
// Deploy with:
//   az deployment group create -g <lab-rg> --template-file main.bicep \
//     --parameters main.bicepparam
// The backup INSTANCE (configure backup) is created by deploy.sh with the
// Azure CLI, which is the documented path for vaulted blob backup.
// =============================================================================

@description('Short lowercase suffix matching the lab.')
@minLength(3)
@maxLength(8)
param suffix string

@description('Region. The vault protects accounts in its own region.')
param location string = resourceGroup().location

@description('Resource ID of the Resource Guard deployed by guard.bicep.')
param resourceGuardId string

@description('Vaulted blob retention (ISO 8601 duration).')
param retention string = 'P30D'

var vaultName = 'bvault-lab03-${suffix}'
var storageAccountName = 'stlab03${suffix}'

module storage '../../modules/storage-account.bicep' = {
  name: 'lab03-storage'
  params: {
    name: storageAccountName
    location: location
    sku: 'Standard_ZRS'
    enableVersioning: true
    enableChangeFeed: true
    blobSoftDeleteDays: 7
    containerSoftDeleteDays: 7
    allowSharedKeyAccess: false
    containers: [
      { name: 'research-active' }
      { name: 'research-reference' }
    ]
    tags: {
      ResearchUnit: 'GSC'
      DataClass: 'GenomicSequences'
      RetentionClass: 'Project'
      Project: 'UMN-Azure-Course'
      Owner: 'lab-attendee'
    }
  }
}

module vault '../../modules/backup-vault.bicep' = {
  name: 'lab03-vault'
  params: {
    name: vaultName
    location: location
    redundancy: 'LocallyRedundant'
    immutabilityState: 'Unlocked'
    softDeleteState: 'On'
    softDeleteRetentionDays: 14
    createBlobVaultedPolicy: true
    blobPolicyName: 'blob-vaulted-daily'
    blobRetentionDuration: retention
    tags: {
      Project: 'UMN-Azure-Course'
      Owner: 'lab-attendee'
    }
  }
}

module mua '../../modules/backup-vault-mua-link.bicep' = {
  name: 'lab03-mua'
  params: {
    backupVaultName: vault.outputs.vaultName
    resourceGuardId: resourceGuardId
  }
}

// The vault identity needs Storage Account Backup Contributor on the account.
module vaultRole '../../modules/role-assignment.bicep' = {
  name: 'lab03-vault-role'
  params: {
    storageAccountName: storage.outputs.name
    principalId: vault.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: 'e5e2a7ff-d759-4cd2-bb51-3152d37e2eb1'
    assignmentDescription: 'Lab 3: Backup vault identity, Storage Account Backup Contributor'
  }
}

output vaultName string = vault.outputs.vaultName
output vaultPrincipalId string = vault.outputs.principalId
output blobPolicyId string = vault.outputs.blobPolicyId
output storageAccountName string = storage.outputs.name
output storageAccountId string = storage.outputs.id
