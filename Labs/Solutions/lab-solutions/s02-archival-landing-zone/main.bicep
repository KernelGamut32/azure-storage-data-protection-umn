// =============================================================================
// Session 2 lab solution: archival landing zone with identity-based access
// Scope: resource group (the attendee's lab resource group)
// Deploy with:
//   az deployment group create -g <lab-rg> --template-file main.bicep \
//     --parameters main.bicepparam
// Builds:
//   1. Standard GPv2 account, flat namespace, ZRS, versioning on, last access
//      tracking OFF (incompatible with immutable storage), shared key disabled
//   2. Container "satellite-archive" with an UNLOCKED time-based retention policy
//   3. Lifecycle rule to Archive based on creation time, scoped to the
//      RetentionClass=Permanent blob index tag
//   4. Storage Blob Data Reader for the lab user with an ABAC condition that
//      only allows reads where the blob's ResearchUnit tag matches
// =============================================================================

@description('Short lowercase suffix that makes the account name unique (attendee initials plus digits, for example "ajs07").')
@minLength(3)
@maxLength(8)
param suffix string

@description('Region. Must support availability zones for ZRS.')
param location string = resourceGroup().location

@description('Object ID of the lab user who receives conditional read access.')
param labUserObjectId string

@description('Research unit tag value the lab user may read.')
param allowedResearchUnit string = 'PGRL'

@description('Retention interval for the unlocked policy. Keep short in the lab so cleanup is simple.')
@minValue(1)
param retentionDays int = 1

@description('Days after creation before Permanent blobs move to Archive.')
@minValue(1)
param daysToArchive int = 1

var storageAccountName = 'stlab02${suffix}'

module storage '../../modules/storage-account.bicep' = {
  name: 'lab02-storage'
  params: {
    name: storageAccountName
    location: location
    // GRS, not ZRS: the lab's tierToArchive rule and Archive rehydration step
    // require a redundancy without zone replication (LRS, GRS, RA-GRS).
    sku: 'Standard_GRS'
    accessTier: 'Hot'
    enableHierarchicalNamespace: false
    enableVersioning: true
    enableChangeFeed: false
    blobSoftDeleteDays: 7
    containerSoftDeleteDays: 7
    enableLastAccessTracking: false
    allowSharedKeyAccess: false
    containers: [
      { name: 'manifests' }
    ]
    tags: {
      ResearchUnit: allowedResearchUnit
      DataClass: 'SatelliteTelemetry'
      RetentionClass: 'Permanent'
      Owner: 'lab-attendee'
      Project: 'UMN-Azure-Course'
    }
  }
}

module worm '../../modules/immutable-container.bicep' = {
  name: 'lab02-worm'
  params: {
    storageAccountName: storage.outputs.name
    containerName: 'satellite-archive'
    retentionDays: retentionDays
  }
}

module lifecycle '../../modules/lifecycle-policy.bicep' = {
  name: 'lab02-lifecycle'
  params: {
    storageAccountName: storage.outputs.name
    rules: [
      {
        enabled: true
        name: 'permanent-to-archive-by-creation'
        type: 'Lifecycle'
        definition: {
          filters: {
            blobTypes: [ 'blockBlob' ]
            blobIndexMatch: [
              {
                name: 'RetentionClass'
                op: '=='
                value: 'Permanent'
              }
            ]
          }
          actions: {
            baseBlob: {
              tierToArchive: {
                daysAfterCreationGreaterThan: daysToArchive
              }
            }
          }
        }
      }
    ]
  }
}

// ABAC: read only blobs whose ResearchUnit tag equals the allowed unit.
// Syntax reference: Microsoft Learn, "Example Azure role assignment conditions for Blob Storage".
var readerCondition = '((!(ActionMatches{\'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read\'} AND NOT SubOperationMatches{\'Blob.List\'})) OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags:ResearchUnit<$key_case_sensitive$>] StringEquals \'${allowedResearchUnit}\'))'

module readerAssignment '../../modules/role-assignment.bicep' = {
  name: 'lab02-reader-abac'
  params: {
    storageAccountName: storage.outputs.name
    principalId: labUserObjectId
    principalType: 'User'
    roleDefinitionId: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
    condition: readerCondition
    assignmentDescription: 'Lab 2: Storage Blob Data Reader limited by ResearchUnit blob index tag'
  }
}

output storageAccountName string = storage.outputs.name
output blobEndpoint string = storage.outputs.primaryBlobEndpoint
output wormContainer string = worm.outputs.containerName
output abacCondition string = readerCondition
