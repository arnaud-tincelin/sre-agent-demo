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
  # Code Access clones the default branch unless a branch is named. When the demo
  # runs from a feature branch the agent would otherwise investigate code that does
  # not contain the fault, so pin it to the branch that is actually deployed.
  GITHUB_BRANCH="${GITHUB_BRANCH:-$(git -C "$(dirname "$0")/.." rev-parse --abbrev-ref HEAD 2>/dev/null || true)}"
  # The top-level name must match the {repoName} path segment or the API returns
  # 400 ObjectNameMismatch when the repo already exists.
  CODE_BODY=$(jq -n \
    --arg name "${REPO_NAME}" \
    --arg url "https://github.com/${GITHUB_REPO}" \
    --arg pat "${GITHUB_PAT}" \
    --arg branch "${GITHUB_BRANCH}" \
    '{name: $name, type: "CodeRepo", properties: ({url: $url, type: "GitHub", pat: $pat}
      + (if $branch == "" or $branch == "HEAD" then {} else {branch: $branch} end))}')
  CODE_STATUS=$(curl -s -o /tmp/sre-code-access.json -w '%{http_code}' \
    -X PUT "${AGENT_ENDPOINT}/api/v2/repos/${REPO_NAME}" \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    -d "${CODE_BODY}" || echo "000")
  case "${CODE_STATUS}" in
    200 | 201)
      echo "  Code Access connected for ${GITHUB_REPO} (repo '${REPO_NAME}', branch '${GITHUB_BRANCH:-default}')."
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

# ── 1. Apply sre-config ───────────────────────────────
# Everything the agent reads at runtime - global instructions, knowledge, skills,
# subagents, and response plans - is declared in sre-config/ and applied from here.
CONFIG_DIR="$(cd "$(dirname "$0")/../sre-config" && pwd)"
CONFIG_FILE="${CONFIG_DIR}/agent-config.json"

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "ERROR: ${CONFIG_FILE} not found."
  exit 1
fi

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGE_DIR}"' EXIT

# ${GITHUB_REPO} and ${RG} are the only placeholders allowed in sre-config markdown.
render() {
  sed -e "s|\${GITHUB_REPO}|${GITHUB_REPO:-the connected repository}|g" \
      -e "s|\${RG}|${RG}|g" "$1"
}

echo "==> Applying global custom instructions..."
CI_FILE="${CONFIG_DIR}/$(jq -r '.customInstructions' "${CONFIG_FILE}")"
CI_STATUS=$(render "${CI_FILE}" | jq -Rs '{instructions: .}' \
  | curl -s -o /dev/null -w '%{http_code}' \
    -X PUT "${AGENT_ENDPOINT}/api/v2/agent/customInstructions" \
    -H "${AUTH_HEADER}" -H "Content-Type: application/json" -d @- || echo "000")
case "${CI_STATUS}" in
  200 | 201 | 204) echo "  $(basename "${CI_FILE}") applied." ;;
  *) echo "  WARNING: custom instructions returned HTTP ${CI_STATUS}." ;;
esac

echo "==> Uploading knowledge base..."
KB_ARGS=()
while IFS= read -r rel; do
  render "${CONFIG_DIR}/${rel}" > "${STAGE_DIR}/$(basename "${rel}")"
  KB_ARGS+=(-F "files=@${STAGE_DIR}/$(basename "${rel}");type=text/plain")
  echo "  ${rel}"
done < <(jq -r '.knowledgeBase[]' "${CONFIG_FILE}")

if [ ${#KB_ARGS[@]} -gt 0 ]; then
  KB_STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "${AGENT_ENDPOINT}/api/v1/AgentMemory/upload" \
    -H "${AUTH_HEADER}" \
    -F "triggerIndexing=true" \
    "${KB_ARGS[@]}" || echo "000")
  case "${KB_STATUS}" in
    200 | 201 | 202) echo "  uploaded, indexing." ;;
    *) echo "  WARNING: knowledge base upload returned HTTP ${KB_STATUS}." ;;
  esac
fi

# Skills are progressive disclosure: the description decides when the body gets
# loaded, so it has to describe the trigger rather than just the topic.
#
# PUT /api/v2/extendedAgent/skills/{name} is idempotent and stores the body in a
# readable skillContent property, so the verify step can diff it against source.
# (The other route - POST /api/v2/agent/skills - needs the body nested in files[]
# with fileName, filePath AND content, silently ignores a top-level content
# field, and exposes no way to read the result back.)
echo "==> Applying skills..."
while IFS= read -r rel; do
  SKILL_PATH="${CONFIG_DIR}/${rel}"
  SKILL_ID=$(sed -n 's/^name: //p' "${SKILL_PATH}" | head -1)
  SKILL_DESC=$(sed -n 's/^description: //p' "${SKILL_PATH}" | head -1)
  SKILL_BODY=$(render "${SKILL_PATH}" | awk 'BEGIN { d = 0 } /^---$/ { d++; next } d >= 2 { print }')

  SKILL_STATUS=$(jq -n \
      --arg id "${SKILL_ID}" \
      --arg desc "${SKILL_DESC}" \
      --arg content "${SKILL_BODY}" \
      '{
        name: $id,
        type: "Skill",
        tags: [],
        properties: {
          name: $id,
          description: $desc,
          tools: [],
          skillContent: $content,
          additionalFiles: [],
          sourcePluginInstallation: null
        }
      }' \
    | curl -s -o /dev/null -w '%{http_code}' \
      -X PUT "${AGENT_ENDPOINT}/api/v2/extendedAgent/skills/${SKILL_ID}" \
      -H "${AUTH_HEADER}" -H "Content-Type: application/json" -d @- || echo "000")

  case "${SKILL_STATUS}" in
    200 | 201 | 202 | 204) echo "  ${SKILL_ID}: applied" ;;
    *) echo "  WARNING: skill ${SKILL_ID} returned HTTP ${SKILL_STATUS}" ;;
  esac
done < <(jq -r '.skills[]' "${CONFIG_FILE}")

# ── 2. Create the scenario subagents ───────────────────────────────────
echo "==> Creating scenario subagents..."

# The tool grants are the real guardrail: code-investigator gets no Azure write
# tool, platform-operator gets no terminal. Neither can do the other's job even if
# the model is talked into trying. Grants live in sre-config/agent-config.json and
# are cross-checked against the live roster in the verify step, because the API
# accepts unknown tool names silently.
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

while IFS= read -r sub; do
  SUB_NAME=$(jq -r '.name' <<<"${sub}")
  SUB_HANDOFF=$(jq -r '.handoffDescription' <<<"${sub}")
  SUB_TOOLS=$(jq -c '.tools' <<<"${sub}")
  SUB_INSTRUCTIONS=$(render "${CONFIG_DIR}/$(jq -r '.instructions' <<<"${sub}")")
  create_subagent "${SUB_NAME}" "${SUB_HANDOFF}" "${SUB_INSTRUCTIONS}" "${SUB_TOOLS}"
done < <(jq -c '.subagents[]' "${CONFIG_FILE}")

# ── 3. Create the response plans ───────────────────────────────────────────────
echo "==> Creating response plans..."

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
      name: $id,
      type: "IncidentFilter",
      tags: [],
      properties: {
        name: $name,
        incidentPlatform: "AzMonitor",
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
      }
    }')
  local status
  status=$(curl -s -o /dev/null -w '%{http_code}' \
    -X PUT "${AGENT_ENDPOINT}/api/v2/extendedAgent/incidentFilters/${id}" \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    -d "${body}" || echo "000")
  case "${status}" in
    200 | 201 | 202 | 204) echo "  ${id} -> ${subagent}" ;;
    *) echo "  WARNING: response plan ${id} returned HTTP ${status}" ;;
  esac
}

# The platform auto-creates a catch-all plan that would swallow both scenarios.
curl -s -o /dev/null -X DELETE \
  "${AGENT_ENDPOINT}/api/v1/incidentPlayground/filters/quickstart_response_plan" \
  -H "${AUTH_HEADER}" || true

# Routing keys off titleContains, so the filters must stay non-overlapping: every
# alert name contains "zava", hence matching on the scenario-specific portion.
while IFS= read -r plan; do
  create_response_plan \
    "$(jq -r '.id' <<<"${plan}")" \
    "$(jq -r '.name' <<<"${plan}")" \
    "$(jq -r '.titleContains' <<<"${plan}")" \
    "$(jq -r '.handlingAgent' <<<"${plan}")"
done < <(jq -c '.responsePlans[]' "${CONFIG_FILE}")

# ── 4. Verify ─────────────────────────────────────────────────────────────────
echo "==> Verifying agent configuration..."

echo "  Knowledge base:"
# Indexing is asynchronous. For a few seconds after upload a file reports
# isIndexed=false with a scary "could not be indexed" reason, then settles.
KB_JSON=""
for _ in 1 2 3 4 5 6; do
  KB_JSON=$(curl -s "${AGENT_ENDPOINT}/api/v1/AgentMemory/files" -H "${AUTH_HEADER}")
  if [ "$(jq -r '[.files[]? | select(.isIndexed | not)] | length' <<<"${KB_JSON}" 2>/dev/null || echo 1)" = "0" ]; then
    break
  fi
  sleep 5
done
jq -r '.files[]? | "    \(.name) indexed=\(.isIndexed)"' <<<"${KB_JSON}" || echo "    (unavailable)"

echo "  Skills:"
# skillContent is readable, so diff the deployed body against source rather than
# trusting the PUT status.
for rel in $(jq -r '.skills[]' "${CONFIG_FILE}"); do
  SKILL_ID=$(sed -n 's/^name: //p' "${CONFIG_DIR}/${rel}" | head -1)
  LOCAL=$(render "${CONFIG_DIR}/${rel}" | awk 'BEGIN { d = 0 } /^---$/ { d++; next } d >= 2 { print }')
  REMOTE=$(curl -s "${AGENT_ENDPOINT}/api/v2/extendedAgent/skills" -H "${AUTH_HEADER}" \
    | jq -r --arg n "${SKILL_ID}" '.value[] | select(.name == $n) | .properties.skillContent // ""')
  if [ "$(printf '%s' "${LOCAL}" | tr -d '\r' | sed -e 's/[[:space:]]*$//')" = "$(printf '%s' "${REMOTE}" | tr -d '\r' | sed -e 's/[[:space:]]*$//')" ]; then
    echo "    ${SKILL_ID} matches source ($(printf '%s' "${REMOTE}" | wc -c) chars)"
  else
    echo "    WARNING: ${SKILL_ID} differs from source (local=$(printf '%s' "${LOCAL}" | wc -c) remote=$(printf '%s' "${REMOTE}" | wc -c) chars)"
  fi
done

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
curl -s "${AGENT_ENDPOINT}/api/v2/extendedAgent/incidentFilters" -H "${AUTH_HEADER}" \
  | jq -r '.value[]? | select(.properties.isEnabled) | "    \(.name) titleContains=\"\(.properties.titleContains)\" -> \(if .properties.handlingAgent == "" then "(none)" else .properties.handlingAgent end) [\(.properties.agentMode)]"' || echo "    (unavailable)"

echo "==> SRE Agent configuration complete."
