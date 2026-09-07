#!/usr/bin/env bash
# break-config.sh - Scenario 2: inject a platform fault.
#
# Overwrites the backend's CATALOG_SOURCE with a provider the deployed image does
# not implement. Container Apps rolls out a new revision, every /api/catalog*
# route starts returning HTTP 503, and the storefront banner goes red.
#
# Nothing in the application image changes: this fault exists only in Azure
# configuration, so the only possible fix is an Azure resource operation.
#
# Reset with: bash scripts/fix-config.sh

set -euo pipefail

BAD_CATALOG_SOURCE="${BAD_CATALOG_SOURCE:-cosmosdb-prod}"

source "$(dirname "$0")/_demo-env.sh"

echo "==> Breaking Zava: setting CATALOG_SOURCE=${BAD_CATALOG_SOURCE} on ${BACKEND_APP}"

az containerapp update \
  --resource-group "${RG}" \
  --name "${BACKEND_APP}" \
  --set-env-vars "CATALOG_SOURCE=${BAD_CATALOG_SOURCE}" \
  --output none

REVISION=$(az containerapp show \
  --resource-group "${RG}" \
  --name "${BACKEND_APP}" \
  --query "properties.latestRevisionName" \
  --output tsv)

echo
echo "  Broken at:    $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "  New revision: ${REVISION}"
echo "  Storefront:   ${FRONTEND_URL}"
echo
echo "The storefront banner turns red once the new revision takes traffic."
echo "The '${AVAILABILITY_ALERT}' alert fires within about 5-10 minutes and the"
echo "platform-operator subagent repairs the configuration."