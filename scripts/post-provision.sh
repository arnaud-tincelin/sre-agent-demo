#!/usr/bin/env bash
# post-provision.sh - Configure the Azure SRE Agent after infrastructure is provisioned.
#
# Called automatically by `azd up` via the postprovision hook in azure.yaml.
# Requires the following azd environment variables to be set before running:
#
#   AZURE_RESOURCE_GROUP    - resource group that was provisioned
#   AZURE_SUBSCRIPTION_ID   - subscription ID
#   AZURE_ENV_NAME          - azd environment name
#   GITHUB_REPOSITORY       - owner/repo for GitHub issue creation (e.g. "myorg/sre-agent-demo")
#   GITHUB_PAT              - fine-grained PAT with 'repo' scope, used to connect Code Access
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
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.App/agents/${AGENT_NAME}?api-version=2025-05-01-preview" \
  --query "properties.agentEndpoint" \
  --output tsv 2>/dev/null || true)

if [ -z "${AGENT_ENDPOINT}" ]; then
  echo "WARNING: Could not resolve SRE Agent endpoint. Skipping data-plane configuration."
  echo "  The agent resource may still be provisioning, or the preview API version may have changed."
  exit 0
fi

echo "  Agent endpoint: ${AGENT_ENDPOINT}"

# ── Acquire access token ──────────────────────────────────────────────────────
# Data-plane calls require a token scoped to the SRE Agent data-plane audience.
TOKEN=$(az account get-access-token \
  --resource "https://azuresre.dev" \
  --query accessToken \
  --output tsv)

AUTH_HEADER="Authorization: Bearer ${TOKEN}"

# ── 0. Connect source code (Code Access) ──────────────────────────────────────
# Gives the agent read access to the repo so it can do root-cause analysis with
# file:line references and error-to-source correlation. This is the "Code"
# source shown in the agent Overview — it cannot be set via ARM/Bicep (GitHub is
# not a valid ARM dataConnectorType), only through this data-plane call.
# API: PUT {endpoint}/api/v2/repos/{repoName}
if [ -n "${GITHUB_REPO}" ] && [ -n "${GITHUB_PAT:-}" ]; then
  echo "==> Connecting source code (Code Access) for ${GITHUB_REPO}..."
  REPO_NAME="${GITHUB_REPO##*/}"
  # The top-level name must match the {repoName} path segment or the API returns
  # 400 ObjectNameMismatch when the repo already exists.
  CODE_BODY=$(jq -n \
    --arg name "${REPO_NAME}" \
    --arg url "https://github.com/${GITHUB_REPO}" \
    --arg pat "${GITHUB_PAT}" \
    '{name: $name, type: "CodeRepo", properties: {url: $url, type: "GitHub", pat: $pat}}')
  CODE_STATUS=$(curl -s -o /tmp/sre-code-access.json -w '%{http_code}' \
    -X PUT "${AGENT_ENDPOINT}/api/v2/repos/${REPO_NAME}" \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    -d "${CODE_BODY}" || echo "000")
  case "${CODE_STATUS}" in
    200 | 201)
      echo "  Code Access connected for ${GITHUB_REPO} (repo '${REPO_NAME}')."
      ;;
    *)
      echo "  WARNING: Code Access request returned HTTP ${CODE_STATUS}."
      echo "           Response: $(head -c 400 /tmp/sre-code-access.json 2>/dev/null)"
      echo "           You can finish it in the portal: Builder > Code Access."
      ;;
  esac
  rm -f /tmp/sre-code-access.json
else
  echo "  Skipping Code Access: GITHUB_REPOSITORY and GITHUB_PAT are both required."
fi

# ── 1. Upload runbooks (knowledge-base documents) ───────────────────────────────
echo "==> Uploading Zava runbooks to knowledge base..."

# Knowledge base ingestion is a multipart file upload, not a JSON document POST.
KB_DIR="$(mktemp -d)"
trap 'rm -rf "${KB_DIR}"' EXIT

# Scenario 1 - code fault. HTTP 500 raised by an unhandled exception.
APP_ERRORS_RUNBOOK=$(cat <<'RUNBOOK_EOF'
# Zava Runbook: HTTP 500 / application exceptions

## Scope
Use this runbook when the Zava storefront returns HTTP 500 and the backend is
recording unhandled exceptions. Alert name contains `app-exception`.

## Environment
- Storefront: React SPA on Azure Container Apps; nginx proxies `/api/*` to the backend.
- Backend: .NET minimal API on Container App `ca-zava-backend-*`, container `zava-backend`,
  telemetry role name `zava-backend`.
- Source: the repository connected under Code Access. Backend entry point is
  `src/backend/Program.cs`.

## Diagnose
Telemetry note: `AppRoleName` is the Container App name (`ca-zava-backend-<env>`),
not the container name. Match on the prefix.

Exceptions with type, message, and stack trace:
```kusto
AppExceptions
| where AppRoleName startswith "ca-zava-backend"
| project TimeGenerated, ProblemId, OuterType, OuterMessage, Details, OperationId
| order by TimeGenerated desc
| take 20
```

Which routes are failing, and how many requests are affected:
```kusto
AppRequests
| where AppRoleName startswith "ca-zava-backend"
| summarize Total = count(), Failed = countif(ResultCode == "500") by Name, bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

Correlate a failing request with its exception through `OperationId`:
```kusto
AppRequests
| where AppRoleName startswith "ca-zava-backend" and ResultCode == "500"
| join kind=inner (AppExceptions | where AppRoleName startswith "ca-zava-backend") on OperationId
| project TimeGenerated, Name, Url, OuterType, OuterMessage, Details
| order by TimeGenerated desc
```

Container console output for the same window:
```kusto
ContainerAppConsoleLogs_CL
| where ContainerName_s == "zava-backend"
| order by TimeGenerated desc
| take 50
```

## Root cause analysis
The `Details` column of `AppExceptions` carries the parsed stack trace, including the
method, source file, and line number. Open that file in the connected repository, read
the surrounding code, and identify the exact statement that threw and why. Always
report the root cause as `file:line`.

## Remediation policy
Application exceptions are code defects. They are NOT remediable from the Azure control
plane. Do not scale, restart, roll back, or reconfigure the Container App in response to
this alert - it cannot fix the defect and it destroys evidence.

The correct action is to file a GitHub issue in the connected repository so the owning
team can ship a fix.

## Issue content
- Alert name and firing time
- Customer-visible symptom and how to reproduce it from the storefront
- Exception type and message
- Stack frame with `file:line`
- The offending code, quoted from the repository
- Number of affected requests and the time window
- A concrete, minimal suggested fix
- An explicit note that no Azure resource was modified
RUNBOOK_EOF
)

# Scenario 2 - platform fault. HTTP 503 caused by an invalid Container App configuration.
PLATFORM_RUNBOOK=$(cat <<'RUNBOOK_EOF'
# Zava Runbook: catalog unavailable / HTTP 503

## Scope
Use this runbook when the Zava storefront catalog is unavailable and the backend
returns HTTP 503. Alert name contains `availability`.

## Environment
- Backend Container App: `ca-zava-backend-*`, container `zava-backend`.
- The backend reads its catalog provider from the `CATALOG_SOURCE` environment
  variable, supplied by the Container App configuration.
- Known-good value: `CATALOG_SOURCE=builtin`. It is the only provider this build
  implements. Any other value makes every `/api/catalog*` route return HTTP 503 and
  `/api/health` report `unhealthy`.

## Diagnose
Telemetry note: `AppRoleName` is the Container App name (`ca-zava-backend-<env>`),
not the container name. Match on the prefix.

Confirm the symptom and establish when it started:
```kusto
AppRequests
| where AppRoleName startswith "ca-zava-backend"
| summarize Requests = count(), Unavailable = countif(ResultCode == "503") by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

The backend logs the reason on every failed request:
```kusto
AppTraces
| where AppRoleName startswith "ca-zava-backend"
| where Message has "CONFIG_ERROR"
| order by TimeGenerated desc
| take 20
```

Read the current configuration:
```bash
az containerapp show -g <RG> -n <BACKEND_APP> --query "properties.template.containers[0].env" -o table
```

List revisions to see when a new one appeared and which one serves traffic:
```bash
az containerapp revision list -g <RG> -n <BACKEND_APP> --query "[].{name:name, created:properties.createdTime, active:properties.active, traffic:properties.trafficWeight}" -o table
```

Find the change that caused it:
```bash
az monitor activity-log list -g <RG> --offset 6h --query "[?contains(operationName.value, 'Microsoft.App/containerApps/write')].{time:eventTimestamp, caller:caller, status:status.value}" -o table
```

## Remediation
This is a platform configuration fault, not a code defect. Do not open a GitHub issue
for it and do not request a code change - the deployed image is correct.

Restore the known-good value:
```bash
az containerapp update -g <RG> -n <BACKEND_APP> --set-env-vars CATALOG_SOURCE=builtin
```

## Verify
1. `az containerapp show` reports `CATALOG_SOURCE=builtin`.
2. The new revision reaches a healthy running state and takes 100% of traffic.
3. `/api/health` returns HTTP 200 with `status: healthy`.
4. The `AppRequests` query above shows `Unavailable` back at zero.
RUNBOOK_EOF
)

printf '%s\n' "${APP_ERRORS_RUNBOOK}" > "${KB_DIR}/zava-app-errors.md"
printf '%s\n' "${PLATFORM_RUNBOOK}" > "${KB_DIR}/zava-platform-config.md"

KB_STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
  -X POST "${AGENT_ENDPOINT}/api/v1/AgentMemory/upload" \
  -H "${AUTH_HEADER}" \
  -F "triggerIndexing=true" \
  -F "files=@${KB_DIR}/zava-app-errors.md;type=text/plain" \
  -F "files=@${KB_DIR}/zava-platform-config.md;type=text/plain" || echo "000")

case "${KB_STATUS}" in
  200 | 201 | 202)
    echo "  Uploaded zava-app-errors.md and zava-platform-config.md (indexing)."
    ;;
  *)
    echo "  WARNING: knowledge base upload returned HTTP ${KB_STATUS}."
    ;;
esac

# ── 2. Create the scenario subagents ───────────────────────────────────
echo "==> Creating scenario subagents..."

# The tool grants are the real guardrail: code-investigator gets no Azure write
# tool, platform-operator gets no terminal. Neither can do the other's job even if
# the model is talked into trying.
#
# Every name below is verified against GET /api/v2/agent/tools on a live agent.
# The API accepts unknown tool names silently, so a typo becomes a tool the
# subagent simply never has. This agent build exposes no CreateGithubIssue tool,
# so the issue is filed from the sandbox terminal against the GitHub REST API.
CODE_INVESTIGATOR_TOOLS='["SearchMemory","SearchIncidentKnowledge","QueryLogAnalyticsByWorkspaceId","QueryAppInsightsByResourceId","RunAzCliReadCommands","FindConnectedGitHubRepo","ListDir","FileSearch","GrepSearch","ReadFile","RunInTerminal"]'
PLATFORM_OPERATOR_TOOLS='["SearchMemory","SearchIncidentKnowledge","QueryLogAnalyticsByWorkspaceId","QueryAppInsightsByResourceId","RunAzCliReadCommands","RunAzCliWriteCommands","system-mcp-monitor_monitor_activitylog_list"]'

create_subagent() {
  local name="$1"
  local handoff="$2"
  local instructions="$3"
  local tools="$4"
  local body
  body=$(jq -n \
    --arg name "${name}" \
    --arg handoff "${handoff}" \
    --arg instructions "${instructions}" \
    --argjson tools "${tools}" \
    '{
      name: $name,
      type: "ExtendedAgent",
      tags: [],
      owner: "",
      properties: {
        instructions: $instructions,
        handoffDescription: $handoff,
        handoffs: [],
        tools: $tools,
        mcpTools: [],
        allowParallelToolCalls: true,
        enableSkills: true
      }
    }')
  local status
  status=$(curl -s -o /dev/null -w '%{http_code}' \
    -X PUT "${AGENT_ENDPOINT}/api/v2/extendedAgent/agents/${name}" \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    -d "${body}" || echo "000")
  case "${status}" in
    200 | 201 | 202 | 204) echo "  ${name}: configured" ;;
    *) echo "  WARNING: ${name} returned HTTP ${status}" ;;
  esac
}

# Scenario 1 - investigates code defects, files a GitHub issue, changes nothing in Azure.
CODE_INVESTIGATOR_INSTRUCTIONS="You are a software reliability investigator for the Zava storefront.

You handle alerts about HTTP 500 errors and unhandled exceptions in the Zava backend
(alert name contains 'app-exception'). Follow the zava-app-errors.md runbook.

1. Confirm the symptom and its blast radius.
   AppRequests | where AppRoleName startswith \"ca-zava-backend\" | summarize Total = count(), Failed = countif(ResultCode == \"500\") by Name, bin(TimeGenerated, 5m) | order by TimeGenerated desc

2. Retrieve the exception, including its stack trace.
   AppExceptions | where AppRoleName startswith \"ca-zava-backend\" | project TimeGenerated, ProblemId, OuterType, OuterMessage, Details, OperationId | order by TimeGenerated desc | take 20

3. Locate the defect in source. The Details column contains the stack trace with a
   source file and line number. The connected repository is cloned into your
   workspace - use FindConnectedGitHubRepo, then ListDir, GrepSearch, and ReadFile to
   open that file, read the surrounding code, and identify the exact statement that
   throws and why it throws.

4. Do NOT remediate from Azure. This is a code defect. Do not scale, restart, roll back,
   or reconfigure the Container App - there is no platform fix for it, and changing the
   app destroys the evidence. You have deliberately not been given any Azure write tool.

5. Open a GitHub issue in ${GITHUB_REPO:-the connected repository} using RunInTerminal.
   Prefer the gh CLI:
     gh issue create --repo ${GITHUB_REPO:-<owner/repo>} --title '<title>' --body '<body>'
   If gh is unavailable or unauthenticated, fall back to the GitHub REST API with curl.
   Title it '[SRE] HTTP 500 on <route> - <ExceptionType>'. The body must contain:
   - Alert name and firing time
   - Customer-visible symptom and how to reproduce it from the storefront
   - Exception type and message
   - The stack frame with file:line
   - The offending code, quoted from the repository
   - Number of affected requests and the time window
   - A concrete, minimal suggested fix
   - An explicit note that no Azure resource was modified

6. Summarise the investigation in the incident thread and link the issue you created.
   If issue creation fails, report the exact command and the error you got rather than
   silently skipping the step."

# Scenario 2 - repairs Container App configuration, files no issue.
PLATFORM_OPERATOR_INSTRUCTIONS="You are a platform operator for the Zava storefront running on Azure Container Apps.

You handle alerts about catalog unavailability and HTTP 503 responses (alert name
contains 'availability'). Follow the zava-platform-config.md runbook.

The backend Container App is in resource group ${RG} and its name starts with
'ca-zava-backend'.

1. Confirm the outage and establish when it started.
   AppRequests | where AppRoleName startswith \"ca-zava-backend\" | summarize Requests = count(), Unavailable = countif(ResultCode == \"503\") by bin(TimeGenerated, 5m) | order by TimeGenerated desc

2. Read the failure reason from the application logs.
   AppTraces | where AppRoleName startswith \"ca-zava-backend\" | where Message has \"CONFIG_ERROR\" | order by TimeGenerated desc | take 20

3. Inspect the platform configuration and compare it against the known-good baseline in
   the runbook.
   az containerapp show -g ${RG} -n <BACKEND_APP> --query \"properties.template.containers[0].env\"
   az containerapp revision list -g ${RG} -n <BACKEND_APP> --query \"[].{name:name, created:properties.createdTime, active:properties.active, traffic:properties.trafficWeight}\"

4. Correlate the outage with the change that introduced it.
   az monitor activity-log list -g ${RG} --offset 6h --query \"[?contains(operationName.value, 'Microsoft.App/containerApps/write')]\"

5. Remediate on the platform by restoring the known-good value.
   az containerapp update -g ${RG} -n <BACKEND_APP> --set-env-vars CATALOG_SOURCE=builtin

6. Verify recovery: re-read the environment variables, wait for the new revision to reach
   a healthy running state with 100% of traffic, and confirm the 503 count returns to zero.

7. Do NOT open a GitHub issue and do NOT request a code change. The deployed image is
   correct; this incident was caused by a configuration change on the Container App.
   You have deliberately not been given GitHub or terminal tools.

8. Post a resolution summary in the incident thread: what broke, when it broke, the change
   that caused it, the command you ran, and the evidence that the storefront recovered."

create_subagent "code-investigator" \
  "Deep root cause analysis of Zava application exceptions using telemetry plus source code; files a GitHub issue. Has no Azure write tools." \
  "${CODE_INVESTIGATOR_INSTRUCTIONS}" \
  "${CODE_INVESTIGATOR_TOOLS}"

create_subagent "platform-operator" \
  "Investigates Zava availability outages and repairs Container App configuration through the Azure CLI. Has no GitHub issue tools." \
  "${PLATFORM_OPERATOR_INSTRUCTIONS}" \
  "${PLATFORM_OPERATOR_TOOLS}"

# ── 3. Create the response plans ───────────────────────────────────────────────
echo "==> Creating response plans..."

# Response plans are incident filters. Routing keys off titleContains, and both
# filters must stay non-overlapping: every alert name contains "zava", so the
# match uses the scenario-specific portion of the name instead.
create_response_plan() {
  local id="$1"
  local name="$2"
  local title_contains="$3"
  local subagent="$4"
  local body
  body=$(jq -n \
    --arg id "${id}" \
    --arg name "${name}" \
    --arg titleContains "${title_contains}" \
    --arg agent "${subagent}" \
    '{
      id: $id,
      name: $name,
      priorities: ["Sev0", "Sev1", "Sev2", "Sev3", "Sev4"],
      titleContains: $titleContains,
      titleContainsAll: [],
      titleContainsAny: [],
      titleNotContains: [],
      handlingAgent: $agent,
      agentMode: "autonomous",
      maxAutomatedInvestigationAttempts: 3,
      mergeEnabled: false,
      mergeWindowHours: 3,
      isEnabled: true
    }')
  local status
  # Delete first so re-running the script updates an existing plan rather than
  # returning 409 and silently leaving the old routing in place.
  curl -s -o /dev/null -X DELETE \
    "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/${id}" \
    -H "${AUTH_HEADER}" || true
  status=$(curl -s -o /dev/null -w '%{http_code}' \
    -X PUT "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/${id}" \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    -d "${body}" || echo "000")
  case "${status}" in
    200 | 201 | 202 | 204 | 409) echo "  ${id} -> ${subagent}" ;;
    *) echo "  WARNING: response plan ${id} returned HTTP ${status}" ;;
  esac
}

# The platform auto-creates a catch-all plan that would swallow both scenarios.
curl -s -o /dev/null -X DELETE \
  "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/quickstart_response_plan" \
  -H "${AUTH_HEADER}" || true

create_response_plan "zava-app-exception" \
  "Zava application exceptions" \
  "app-exception" \
  "code-investigator"

create_response_plan "zava-availability" \
  "Zava catalog availability" \
  "availability" \
  "platform-operator"

# ── 4. Verify ─────────────────────────────────────────────────────────────────
echo "==> Verifying agent configuration..."

echo "  Knowledge base:"
curl -s "${AGENT_ENDPOINT}/api/v1/AgentMemory/files" -H "${AUTH_HEADER}" \
  | jq -r '.files[]? | "    \(.name) indexed=\(.isIndexed)"' || echo "    (unavailable)"

echo "  Subagents:"
# The subagent API accepts unknown tool names silently, so a stale or misspelled
# name becomes a capability the subagent simply never has. Cross-check the grants
# against the live roster instead of trusting the create call's 200.
ROSTER=$(curl -s "${AGENT_ENDPOINT}/api/v2/agent/tools" -H "${AUTH_HEADER}")
curl -s "${AGENT_ENDPOINT}/api/v2/extendedAgent/agents" -H "${AUTH_HEADER}" \
  | jq -r --argjson roster "${ROSTER}" '
      ($roster.data | map(.name)) as $known
      | .value[]?
      | .properties.tools as $t
      | ($t - $known) as $phantom
      | "    \(.name) tools=\($t | length) phantom=\(if ($phantom | length) == 0 then "none" else ($phantom | join(",")) end) azureWrite=\($t | index("RunAzCliWriteCommands") != null) terminal=\($t | index("RunInTerminal") != null)"
    ' || echo "    (unavailable)"

echo "  Response plans:"
curl -s "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters" -H "${AUTH_HEADER}" \
  | jq -r '.[]? | select(.isEnabled) | "    \(.id) titleContains=\"\(.titleContains)\" -> \(if .handlingAgent == "" then "(none)" else .handlingAgent end) [\(.agentMode)]"' || echo "    (unavailable)"

echo "==> SRE Agent configuration complete."
