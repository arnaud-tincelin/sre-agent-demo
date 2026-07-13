#!/usr/bin/env bash
# _demo-env.sh - Shared environment resolution for the demo break/fix scripts.
# Sourced by the other scripts; not meant to be executed directly.

if [ -z "${AZURE_RESOURCE_GROUP:-}" ] || [ -z "${AZURE_ENV_NAME:-}" ]; then
  if command -v azd >/dev/null 2>&1; then
    eval "$(azd env get-values 2>/dev/null | grep -E '^(AZURE_RESOURCE_GROUP|AZURE_ENV_NAME)=' || true)"
  fi
fi

if [ -z "${AZURE_RESOURCE_GROUP:-}" ] || [ -z "${AZURE_ENV_NAME:-}" ]; then
  echo "ERROR: AZURE_RESOURCE_GROUP and AZURE_ENV_NAME are not set." >&2
  echo "       Run this from the repository root after 'azd up', or export them manually." >&2
  exit 1
fi

RG="$AZURE_RESOURCE_GROUP"
ENV_NAME="$AZURE_ENV_NAME"
BACKEND_APP="ca-zava-backend-${ENV_NAME}"
FRONTEND_APP="ca-zava-frontend-${ENV_NAME}"
APP_EXCEPTION_ALERT="alert-zava-app-exception-${ENV_NAME}"
AVAILABILITY_ALERT="alert-zava-availability-${ENV_NAME}"

FRONTEND_FQDN=$(az containerapp show \
  --resource-group "${RG}" \
  --name "${FRONTEND_APP}" \
  --query "properties.configuration.ingress.fqdn" \
  --output tsv)
FRONTEND_URL="https://${FRONTEND_FQDN}"