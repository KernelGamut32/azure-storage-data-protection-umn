using './main.bicep'

// Attendee initials plus two digits, lowercase, for example 'ajs07'.
param suffix = readEnvironmentVariable('LAB_SUFFIX')

// Object ID of the lab user: az ad signed-in-user show --query id -o tsv
param labUserObjectId = readEnvironmentVariable('LAB_USER_OBJECT_ID')

param allowedResearchUnit = 'PGRL'
param retentionDays = 1
param daysToArchive = 1
