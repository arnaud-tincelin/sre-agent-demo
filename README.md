# sre-agent-demo

Demo environment for an **Azure SRE Agent** paired with a buggy e-commerce app named **Zava**.

## Architecture

```
Zava (Container App)
  │  memory grows unbounded (AVeryMemoryIntensiveFunction)
  │  logs: "AVeryMemoryIntensiveFunction leak size=N"
  │
  ├─ console logs        ──►  Log Analytics (ContainerAppConsoleLogs_CL)
  ├─ OpenTelemetry logs/traces/metrics ──►  Application Insights (AppTraces, AppRequests, …)
  ▼
Azure Monitor metric alert  (WorkingSetBytes > 800 MiB)
  │
  ▼
Action Group  ──►  Azure SRE Agent  (Microsoft.App/agents)
                        │
                        ├─ queries Log Analytics + Application Insights (KQL)
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
   - Queries Log Analytics / Application Insights to confirm `AVeryMemoryIntensiveFunction` as root cause.
   - Scales the Container App to spread load (`az containerapp update`).
   - Opens a GitHub issue with evidence and the mitigation taken.

## What is in this repo

| Path                        | Purpose                                                                                                                                                                                  |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `infra/main.bicep`          | Log Analytics, Application Insights, Container Apps environment, Zava Backend + Frontend Container Apps, managed identity + RBAC, Azure SRE Agent (`Microsoft.App/agents`), metric alert |
| `src/backend/`              | Zava .NET 10 minimal API – catalog endpoint with `AVeryMemoryIntensiveFunction` memory leak                                                                                              |
| `src/frontend/`             | React + Vite SPA – navigates catalog/basket, triggers the backend leak on every page load                                                                                                |
| `scripts/pre-provision.sh`  | Mints a GitHub token via `gh` and auto-detects the repo, storing both in the azd environment so the SRE Agent GitHub connector is configured with no manual steps                        |
| `scripts/post-provision.sh` | Calls the SRE Agent data-plane API to upload the runbook, create the subagent, and create the response plan                                                                              |
| `azure.yaml`                | azd configuration – provisions infra then runs `post-provision.sh`                                                                                                                       |

## Deploy with one command

### Prerequisites

- Azure CLI + Azure Developer CLI (`azd`)
- `az login` / `azd auth login`
- [GitHub CLI](https://cli.github.com) (`gh`) — used to mint the GitHub token automatically

### Steps

```bash
azd up
```

That's it. On `azd up` the `preprovision` hook (`scripts/pre-provision.sh`):

1. Signs you into GitHub via `gh` (requesting the `repo` scope) if you aren't already, and stores the token as `GITHUB_PAT` in the azd environment.
2. Auto-detects the target repository from your `origin` remote and stores it as `GITHUB_REPOSITORY`.

Both values flow into `infra/main.parameters.json` → the Bicep `githubPat` / `githubRepository` parameters → the SRE Agent's GitHub connector.

> Prefer to provide your own token? Set it before running `azd up` and the hook will reuse it:
>
> ```bash
> azd env set GITHUB_REPOSITORY "owner/sre-agent-demo"
> azd env set GITHUB_PAT        "ghp_…"   # PAT with Issues: Read + Write
> ```

`azd up` will:

1. Run `infra/main.bicep` → creates all Azure resources including the SRE Agent.
2. Build and push the Zava container image, update the Container App.
3. Run `scripts/post-provision.sh` → configures the agent knowledge base, subagent, and response plan.

## Local development

```bash
# Terminal 1 – .NET backend on :8080
cd src/backend && dotnet run

# Terminal 2 – React dev server on :5173 (proxies /api/* to :8080)
cd src/frontend && npm install && npm run dev
```

## Triggering the demo

1. Open the Zava URL printed by `azd up`.
2. Click around catalog / basket repeatedly.
3. Each page load leaks ~10 MB. After ~80 clicks the memory alert fires.
4. Watch the Azure SRE Agent diagnose the issue, scale the Container App, and open a GitHub issue.

## Notes

- `GITHUB_PAT` is passed to Bicep as a secure parameter and stored in the SRE Agent as a GitHub connector credential. It is never written to disk or logged.
- The `Microsoft.App/agents` resource type is in **public preview**. The exact Bicep API version and property schema should be verified against current preview documentation.
- The permanent fix for the memory leak is to remove the `AVeryMemoryIntensiveFunction` call in `src/backend/Program.cs`; the SRE Agent mitigation (scaling replicas) only buys time.
