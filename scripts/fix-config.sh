#!/usr/bin/env bash
# fix-config.sh - Scenario 2: manual reset.
#
# Restores the known-good CATALOG_SOURCE. Use this to re-run the scenario, or if
# you want to recover without waiting for the SRE Agent. When the agent has
# already remediated, this is a no-op.

set -euo pipefail

source "$(dirname "$0")/_demo-env.sh"

echo "==> Restoring CATALOG_SOURCE=builtin on ${BACKEND_APP}"

az containerapp update \
  --resource-group "${RG}" \
  --name "${BACKEND_APP}" \
  --set-env-vars "CATALOG_SOURCE=builtin" \
  --output none

echo "  Storefront: ${FRONTEND_URL}"
echo "  The banner returns to green once the new revision takes traffic."