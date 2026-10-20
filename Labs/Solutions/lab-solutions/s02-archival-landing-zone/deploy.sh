#!/usr/bin/env bash
# =============================================================================
# Session 2 lab solution: deploy, seed, and verify the archival landing zone
# Usage:
#   export LAB_RG=rg-lab-07 LAB_SUFFIX=ajs07
#   ./deploy.sh
# Prerequisites: Azure CLI 2.70 or later, Bicep CLI (az bicep install),
#   logged in (az login), subscription selected (az account set -s <id>).
# =============================================================================
set -euo pipefail

: "${LAB_RG:?Set LAB_RG to your lab resource group}"
: "${LAB_SUFFIX:?Set LAB_SUFFIX to attendee initials plus digits, lowercase}"
export LAB_USER_OBJECT_ID="${LAB_USER_OBJECT_ID:-$(az ad signed-in-user show --query id -o tsv)}"
LOCATION="${LOCATION:-$(az group show -n "$LAB_RG" --query location -o tsv)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> 1/6 Deploying Bicep to $LAB_RG"
az deployment group create -g "$LAB_RG" -n lab02-landing-zone \
  --template-file "$SCRIPT_DIR/main.bicep" --parameters "$SCRIPT_DIR/main.bicepparam" -o none
SA=$(az deployment group show -g "$LAB_RG" -n lab02-landing-zone --query properties.outputs.storageAccountName.value -o tsv)
echo "    storage account: $SA"

echo "==> 2/6 Creating a synthetic satellite dataset with an integrity manifest"
WORK=$(mktemp -d)
mkdir -p "$WORK/satellite"
for i in $(seq -w 1 20); do
  head -c $((1024 * 1024 * 2)) /dev/urandom > "$WORK/satellite/noaa19_pass_2026_10_${i}.bin"
done
( cd "$WORK/satellite" && sha256sum *.bin > ../manifest.sha256 )
echo "    $(wc -l < "$WORK/manifest.sha256") objects hashed"

echo "==> 3/6 Granting yourself Storage Blob Data Contributor for the upload (Entra auth, no keys)"
az role assignment create --role "Storage Blob Data Contributor" \
  --assignee-object-id "$LAB_USER_OBJECT_ID" --assignee-principal-type User \
  --scope "$(az storage account show -n "$SA" -g "$LAB_RG" --query id -o tsv)" -o none
echo "    waiting 60 seconds for role propagation"; sleep 60

echo "==> 4/6 Uploading with blob index tags (ResearchUnit and RetentionClass)"
az storage blob upload-batch --account-name "$SA" --auth-mode login \
  -d satellite-archive -s "$WORK/satellite" \
  --tags "ResearchUnit=PGRL" "RetentionClass=Permanent" -o none
az storage blob upload --account-name "$SA" --auth-mode login \
  -c manifests -f "$WORK/manifest.sha256" -n satellite/manifest-2026-10.sha256 \
  --tags "ResearchUnit=PGRL" "RetentionClass=Permanent" -o none

echo "==> 5/6 Proving the WORM policy: delete and overwrite must FAIL"
set +e
az storage blob delete --account-name "$SA" --auth-mode login -c satellite-archive -n noaa19_pass_2026_10_01.bin 2>&1 | tail -1
az storage blob upload --account-name "$SA" --auth-mode login -c satellite-archive -n noaa19_pass_2026_10_01.bin -f "$WORK/manifest.sha256" --overwrite 2>&1 | tail -1
set -e

echo "==> 6/6 Submitting a rehydration test: archive one blob, then request Standard rehydration"
az storage blob set-tier --account-name "$SA" --auth-mode login -c satellite-archive -n noaa19_pass_2026_10_20.bin --tier Archive -o none
az storage blob set-tier --account-name "$SA" --auth-mode login -c satellite-archive -n noaa19_pass_2026_10_20.bin --tier Cool --rehydrate-priority Standard -o none
az storage blob show --account-name "$SA" --auth-mode login -c satellite-archive -n noaa19_pass_2026_10_20.bin \
  --query "{tier:properties.blobTier, archiveStatus:properties.archiveStatus, rehydratePriority:properties.rehydratePriority}" -o table

echo
echo "Done. ABAC validation: list blobs with --auth-mode login; reads succeed on PGRL-tagged blobs only."
echo "Cleanup order (unlocked policy still blocks blob deletes):"
echo "  az storage container immutability-policy delete --account-name $SA -c satellite-archive --if-match '*' -g $LAB_RG"
echo "  az storage container delete --account-name $SA -n satellite-archive --auth-mode login"
echo "  az group delete -n $LAB_RG --yes"
