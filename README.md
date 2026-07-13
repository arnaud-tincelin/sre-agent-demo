# sre-agent-demo

Demo environment for an **Azure SRE Agent** paired with a buggy e-commerce app named **Zava**.

## Architecture

```
Zava (Container App)
  │  memory grows unbounded (AVeryMemoryIntensiveFunction)
  │  logs: "AVeryMemoryIntensiveFunction leak size=N"
  ▼
Azure Monitor metric alert  (WorkingSetBytes > 800 MiB)
  │
  ▼
Action Group  ──►  Azure SRE Agent  (Microsoft.App/agents)
                        │
                        ├─ queries Log Analytics workspace (KQL)
                        │   to confirm root cause
                        │
                        ├─ scales the Zava Container App
                        │   (az containerapp update --max-replicas 4)
                        │
                        └─ opens a GitHub issue in this repo
```

1. Browsing Zava triggers `AVeryMemoryIntensiveFunction` on every request, leaking ~10 MB per call.
2. When working-set memory exceeds 800 MiB the Azure Monitor metric alert fires.
3. The alert routes to the **Azure SRE Agent** via an Action Group.
4. The agent runs a pre-configured **incident-handler** subagent that:
   - Queries Log Analytics to confirm `AVeryMemoryIntensiveFunction` as root cause.
   - Scales the Container App to spread load (`az containerapp update`).
   - Opens a GitHub issue with evidence and the mitigation taken.

## What is in this repo

| Path | Purpose |
|------|---------|
| `infra/main.bicep` | Log Analytics, Container Apps environment, Zava Container App, managed identity + RBAC, Azure SRE Agent (`Microsoft.App/agents`), metric alert |
| `src/web/` | Zava Flask app with the intentional `AVeryMemoryIntensiveFunction` memory bug |
| `scripts/post-provision.sh` | Calls the SRE Agent data-plane API to upload the runbook, create the subagent, and create the response plan |
| `azure.yaml` | azd configuration – provisions infra then runs `post-provision.sh` |

## Deploy with one command

### Prerequisites

- Azure CLI + Azure Developer CLI (`azd`)
- `az login` / `azd auth login`
- A GitHub PAT with **Issues: Read + Write** scope

### Steps

```bash
# 1. Set your GitHub details
azd env set GITHUB_REPOSITORY "owner/sre-agent-demo"
azd env set GITHUB_PAT        "ghp_…"

# 2. Provision infrastructure and deploy Zava
azd up
```

`azd up` will:
1. Run `infra/main.bicep` → creates all Azure resources including the SRE Agent.
2. Build and push the Zava container image, update the Container App.
3. Run `scripts/post-provision.sh` → configures the agent knowledge base, subagent, and response plan.

## Triggering the demo

1. Open the Zava URL printed by `azd up`.
2. Click around catalog / basket repeatedly.
3. Each page load leaks ~10 MB. After ~80 clicks the memory alert fires.
4. Watch the Azure SRE Agent diagnose the issue, scale the Container App, and open a GitHub issue.

## Notes

- `GITHUB_PAT` is passed to Bicep as a secure parameter and stored in the SRE Agent as a GitHub connector credential. It is never written to disk or logged.
- The `Microsoft.App/agents` resource type is in **public preview**. The exact Bicep API version and property schema should be verified against current preview documentation.
- The permanent fix for the memory leak is to remove the `AVeryMemoryIntensiveFunction` call in `src/web/app.py`; the SRE Agent mitigation (scaling replicas) only buys time.

