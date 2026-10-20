// =============================================================================
// Session 3 lab solution, part 1: Resource Guard in the SEPARATE guard
// resource group (rg-lab-NN-guard). In production this group belongs to a
// different team, subscription, or tenant than the vault administrators.
// Deploy with:
//   az deployment group create -g <lab-guard-rg> --template-file guard.bicep \
//     --parameters suffix=<suffix>
// =============================================================================

@description('Short lowercase suffix matching the lab.')
param suffix string

@description('Region.')
param location string = resourceGroup().location

module guard '../../modules/resource-guard.bicep' = {
  name: 'lab03-guard'
  params: {
    name: 'guard-lab03-${suffix}'
    location: location
    criticalOperationExclusionList: []
    tags: {
      Owner: 'security-team'
      Project: 'UMN-Azure-Course'
    }
  }
}

output resourceGuardId string = guard.outputs.resourceGuardId
