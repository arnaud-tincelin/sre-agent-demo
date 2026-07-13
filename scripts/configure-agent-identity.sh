#!/usr/bin/env sh
set -eu

if [ -z "${AZURE_RESOURCE_GROUP:-}" ] || [ -z "${AZURE_SUBSCRIPTION_ID:-}" ]; then
  echo "Skipping identity configuration: azd environment variables are not available."
  exit 0
fi

RG="$AZURE_RESOURCE_GROUP"
SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID"
APP_NAME="sre-agent"
WORKSPACE_NAME="law-${AZURE_ENV_NAME}"

echo "Enabling managed identity for ${APP_NAME}..."
az containerapp identity assign \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RG" \
  --name "$APP_NAME" \
  --system-assigned \
  --only-show-errors >/dev/null

PRINCIPAL_ID=$(az containerapp show \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RG" \
  --name "$APP_NAME" \
  --query identity.principalId -o tsv)

if [ -z "$PRINCIPAL_ID" ]; then
  echo "Could not retrieve principal ID for ${APP_NAME}."
  exit 1
fi

echo "Assigning Contributor role so the SRE agent can scale ACA..."
az role assignment create \
  --subscription "$SUBSCRIPTION_ID" \
  --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG" \
  --only-show-errors >/dev/null || true

WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RG" \
  --workspace-name "$WORKSPACE_NAME" \
  --query id -o tsv)

if [ -n "$WORKSPACE_ID" ]; then
  echo "Assigning Log Analytics Reader role so the SRE agent can query logs..."
  az role assignment create \
    --subscription "$SUBSCRIPTION_ID" \
    --assignee-object-id "$PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Log Analytics Reader" \
    --scope "$WORKSPACE_ID" \
    --only-show-errors >/dev/null || true
fi

echo "SRE agent identity configuration completed."
