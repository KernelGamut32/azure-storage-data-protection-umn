#!/usr/bin/env bash
# =============================================================================
# Session 3 lab solution: Resource Guard, immutable Backup vault with MUA,
# vaulted blob backup, protected-operation test, and alternate-location restore
# Usage:
#   export LAB_RG=rg-lab-07 LAB_GUARD_RG=rg-lab-07-guard LAB_SUFFIX=ajs07
#   ./deploy.sh
# Prerequisites: Azure CLI 2.70 or later with the dataprotection extension
#   (az extension add --name dataprotection), Bicep CLI, az login done.
# =============================================================================
set -euo pipefail
: "${LAB_RG:?Set LAB_RG}"; : "${LAB_GUARD_RG:?Set LAB_GUARD_RG}"; : "${LAB_SUFFIX:?Set LAB_SUFFIX}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCATION=$(az group show -n "$LAB_RG" --query location -o tsv)
az extension add --name dataprotection --upgrade -o none 2>/dev/null || true

echo "==> 1/7 Resource Guard in the separate guard resource group"
az deployment group create -g "$LAB_GUARD_RG" -n lab03-guard \
  --template-file "$SCRIPT_DIR/guard.bicep" --parameters suffix="$LAB_SUFFIX" -o none
export LAB_RESOURCE_GUARD_ID=$(az deployment group show -g "$LAB_GUARD_RG" -n lab03-guard --query properties.outputs.resourceGuardId.value -o tsv)
echo "    $LAB_RESOURCE_GUARD_ID"

echo "==> 2/7 Backup vault (immutability Unlocked, soft delete On), MUA link, storage account, role"
az deployment group create -g "$LAB_RG" -n lab03-vault \
  --template-file "$SCRIPT_DIR/main.bicep" --parameters "$SCRIPT_DIR/main.bicepparam" -o none
VAULT=$(az deployment group show -g "$LAB_RG" -n lab03-vault --query properties.outputs.vaultName.value -o tsv)
SA=$(az deployment group show -g "$LAB_RG" -n lab03-vault --query properties.outputs.storageAccountName.value -o tsv)
SA_ID=$(az deployment group show -g "$LAB_RG" -n lab03-vault --query properties.outputs.storageAccountId.value -o tsv)
POLICY_ID=$(az deployment group show -g "$LAB_RG" -n lab03-vault --query properties.outputs.blobPolicyId.value -o tsv)
echo "    vault $VAULT, account $SA"

echo "==> 3/7 Seeding two containers with sample blobs"
ME=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --role "Storage Blob Data Contributor" --assignee-object-id "$ME" --assignee-principal-type User --scope "$SA_ID" -o none
sleep 60
WORK=$(mktemp -d); mkdir -p "$WORK/a" "$WORK/r"
for i in 1 2 3 4 5; do head -c 524288 /dev/urandom > "$WORK/a/sample_active_$i.bin"; head -c 524288 /dev/urandom > "$WORK/r/sample_reference_$i.bin"; done
az storage blob upload-batch --account-name "$SA" --auth-mode login -d research-active -s "$WORK/a" -o none
az storage blob upload-batch --account-name "$SA" --auth-mode login -d research-reference -s "$WORK/r" -o none

echo "==> 4/7 Configuring vaulted blob backup (role assignment can take up to 30 minutes to propagate)"
# Vaulted blob backup is a two-step initialization: the backup configuration
# names the containers, then the backup instance references that configuration.
az dataprotection backup-instance initialize-backupconfig --datasource-type AzureBlob \
  --storage-account-rg "$LAB_RG" --storage-account-name "$SA" \
  --container-list research-active research-reference > "$WORK/backup_config.json"
az dataprotection backup-instance initialize --datasource-type AzureBlob --datasource-location "$LOCATION" \
  --policy-id "$POLICY_ID" --datasource-id "$SA_ID" \
  --backup-configuration "$WORK/backup_config.json" > "$WORK/backup_instance.json"
for attempt in 1 2 3 4 5 6; do
  if az dataprotection backup-instance validate-for-backup -g "$LAB_RG" --vault-name "$VAULT" --backup-instance "$WORK/backup_instance.json" -o none 2>/dev/null; then break; fi
  echo "    validation not ready yet (attempt $attempt), waiting 5 minutes"; sleep 300
done
az dataprotection backup-instance create -g "$LAB_RG" --vault-name "$VAULT" --backup-instance "$WORK/backup_instance.json" -o none
BI=$(az dataprotection backup-instance list -g "$LAB_RG" --vault-name "$VAULT" --query "[0].name" -o tsv)
echo "    backup instance: $BI"

echo "==> 5/7 Starting an on-demand vaulted backup now (first backup takes time; continue the lab)"
az dataprotection backup-instance adhoc-backup -g "$LAB_RG" --vault-name "$VAULT" -n "$BI" --rule-name BackupDaily --no-wait -o none

echo "==> 6/7 Protected-operation test: disabling immutability WITHOUT Resource Guard authorization must fail"
set +e
az dataprotection backup-vault update -g "$LAB_RG" --vault-name "$VAULT" --immutability-state Disabled 2>&1 | tail -2
set -e
echo "    Expected: the request is rejected until the caller holds Reader on the Resource Guard (ResourceGuardUnauthorized or similar)."

echo "==> 7/7 Restore to an ALTERNATE storage account (run after the first backup completes)"
cat <<EOF
  RP=\$(az dataprotection recovery-point list -g $LAB_RG --vault-name $VAULT --backup-instance-name $BI --query "[0].name" -o tsv)
  ALT_ID=\$(az storage account create -n stlab03alt$LAB_SUFFIX -g $LAB_RG -l $LOCATION --sku Standard_LRS --kind StorageV2 --allow-blob-public-access false --min-tls-version TLS1_2 --query id -o tsv)
  az role assignment create --role "Storage Account Backup Contributor" --assignee-object-id \$(az dataprotection backup-vault show -g $LAB_RG --vault-name $VAULT --query identity.principalId -o tsv) --assignee-principal-type ServicePrincipal --scope \$ALT_ID
  az dataprotection backup-instance restore initialize-for-item-recovery --datasource-type AzureBlob --restore-location $LOCATION --source-datastore VaultStore --recovery-point-id \$RP --target-resource-id \$ALT_ID --container-list research-active > restore.json
  az dataprotection backup-instance validate-for-restore -g $LAB_RG --vault-name $VAULT -n $BI --restore-request-object restore.json
  az dataprotection backup-instance restore trigger -g $LAB_RG --vault-name $VAULT -n $BI --restore-request-object restore.json
  az dataprotection job list -g $LAB_RG --vault-name $VAULT --query "[].{op:properties.operationCategory,status:properties.status,start:properties.startTime}" -o table
EOF
