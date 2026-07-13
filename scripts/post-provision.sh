#!/usr/bin/env bash
# post-provision.sh – Configure the Azure SRE Agent after infrastructure is provisioned.
#
# Called automatically by `azd up` via the postprovision hook in azure.yaml.
# Requires the following azd environment variables to be set before running:
#
#   AZURE_RESOURCE_GROUP    – resource group that was provisioned
#   AZURE_SUBSCRIPTION_ID   – subscription ID
#   AZURE_ENV_NAME          – azd environment name
#   GITHUB_REPOSITORY       – owner/repo for GitHub issue creation (e.g. "myorg/sre-agent-demo")
#
# NOTE: Microsoft.App/agents is a public-preview service. The data-plane API
# endpoints and payload schemas below reflect the preview spec. Verify against
# current preview documentation before deploying to production.

set -euo pipefail

# ── Guard ─────────────────────────────────────────────────────────────────────
if [ -z "${AZURE_RESOURCE_GROUP:-}" ] || [ -z "${AZURE_SUBSCRIPTION_ID:-}" ] || [ -z "${AZURE_ENV_NAME:-}" ]; then
  echo "Skipping SRE Agent configuration: azd environment variables are not available."
  exit 0
fi

RG="$AZURE_RESOURCE_GROUP"
SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID"
ENV_NAME="$AZURE_ENV_NAME"
AGENT_NAME="sre-agent-${ENV_NAME}"
GITHUB_REPO="${GITHUB_REPOSITORY:-}"

echo "==> Configuring SRE Agent: ${AGENT_NAME}"

# ── Resolve data-plane endpoint ───────────────────────────────────────────────
# The agent endpoint is the base URL for all data-plane API calls.
AGENT_ENDPOINT=$(az rest \
  --method GET \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.App/agents/${AGENT_NAME}?api-version=2025-02-02-preview" \
  --query "properties.endpoint" \
  --output tsv 2>/dev/null || true)

if [ -z "${AGENT_ENDPOINT}" ]; then
  echo "WARNING: Could not resolve SRE Agent endpoint. Skipping data-plane configuration."
  echo "  The agent resource may still be provisioning, or the preview API version may have changed."
  exit 0
fi

echo "  Agent endpoint: ${AGENT_ENDPOINT}"

# ── Acquire access token ──────────────────────────────────────────────────────
TOKEN=$(az account get-access-token \
  --resource "https://agents.azure.com" \
  --query accessToken \
  --output tsv)

AUTH_HEADER="Authorization: ******"

# ── 1. Upload runbook (knowledge-base document) ───────────────────────────────
echo "==> Uploading Zava runbook to knowledge base..."

RUNBOOK=$(cat <<'RUNBOOK_EOF'
# Zava Application Runbook

## Overview
Zava is a .NET e-commerce app for pet products, deployed on Azure Container Apps (ACA).

## Intentional memory bug: AVeryMemoryIntensiveFunction
Every HTTP request to the catalog, basket, or add-to-basket routes triggers
`AVeryMemoryIntensiveFunction`, which appends a 10 MB string to a global list
(`LEAK_BUCKET`) and never releases it. This causes unbounded memory growth that
eventually produces container OOM kills.

**Log marker:** The app emits `AVeryMemoryIntensiveFunction leak size=<N>` at
ERROR level. Query in Log Analytics:
```kusto
ContainerAppConsoleLogs_CL
| where ContainerName_s == "zava-backend"
| where Log_s has "AVeryMemoryIntensiveFunction"
| order by TimeGenerated desc
```

## Mitigation
Scale the Container App to spread load across replicas while the root cause
is being investigated:
```bash
az containerapp update \
  --resource-group <RG> \
  --name <CONTAINER_APP_NAME> \
  --max-replicas 4
```
This does **not** fix the leak; it buys time. The permanent fix is to remove
the call to `AVeryMemoryIntensiveFunction` in `src/backend/Program.cs`.

## Escalation
Open a GitHub issue in the repository with:
- Alert name and timestamp
- KQL evidence of the leak marker
- Mitigation action taken (replica count update)
- Link to this runbook
RUNBOOK_EOF
)

curl -s -X POST "${AGENT_ENDPOINT}/knowledgebase/documents" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d "{\"filename\": \"zava-runbook.md\", \"content\": $(echo "${RUNBOOK}" | jq -Rs .)}" \
  | jq -r '.id // "uploaded"' | xargs -I{} echo "  Document ID: {}"

# ── 2. Create the incident-handler subagent ───────────────────────────────────
echo "==> Creating incident-handler subagent..."

SUBAGENT_INSTRUCTIONS="You are an SRE incident responder for the Zava e-commerce application.

When you receive an Azure Monitor OOM or high-memory alert for the Zava Container App:

1. **Diagnose** – Query Log Analytics for recent AVeryMemoryIntensiveFunction entries:
   ContainerAppConsoleLogs_CL | where ContainerName_s == \"zava-backend\" | where Log_s has \"AVeryMemoryIntensiveFunction\" | order by TimeGenerated desc | take 20

2. **Identify root cause** – Confirm that AVeryMemoryIntensiveFunction is the source of
   the memory pressure (look for rapidly increasing leak size values in the logs).

3. **Mitigate** – Scale the Container App to reduce per-replica load:
   az containerapp update --resource-group <RG> --name <CONTAINER_APP> --max-replicas 4

4. **Report** – Open a GitHub issue in ${GITHUB_REPO} titled
   '[SRE] Zava OOM – AVeryMemoryIntensiveFunction detected' with:
   - Alert trigger time and metric value
   - Top 5 log lines showing the leak progression
   - Mitigation action taken (az containerapp update command and result)
   - Reference to the zava-runbook.md knowledge-base document"

curl -s -X POST "${AGENT_ENDPOINT}/subagents" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"incident-handler\",
    \"description\": \"Diagnoses Zava OOM alerts, identifies AVeryMemoryIntensiveFunction as root cause, scales ACA, and opens a GitHub issue.\",
    \"instructions\": $(echo "${SUBAGENT_INSTRUCTIONS}" | jq -Rs .)
  }" \
  | jq -r '.id // "created"' | xargs -I{} echo "  Subagent ID: {}"

# ── 3. Create the response plan ───────────────────────────────────────────────
echo "==> Creating OOM response plan..."

curl -s -X POST "${AGENT_ENDPOINT}/responseplans" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"zava-oom-response\",
    \"description\": \"Routes Azure Monitor memory/OOM alerts from Zava to the incident-handler subagent.\",
    \"trigger\": {
      \"type\": \"AzureMonitorAlert\",
      \"filter\": {
        \"alertNameContains\": \"zava\"
      }
    },
    \"subagent\": \"incident-handler\"
  }" \
  | jq -r '.id // "created"' | xargs -I{} echo "  Response plan ID: {}"

echo "==> SRE Agent configuration complete."
