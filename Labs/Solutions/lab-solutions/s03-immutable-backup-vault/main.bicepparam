using './main.bicep'

param suffix = readEnvironmentVariable('LAB_SUFFIX')
param resourceGuardId = readEnvironmentVariable('LAB_RESOURCE_GUARD_ID')
param retention = 'P30D'
