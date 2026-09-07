# sre-agent-demo

Demo environment for an **Azure SRE Agent** operating a small e-commerce app named **Zava**.

The demo shows the two things an SRE agent does that a human on-call would otherwise do by hand:

| | Scenario 1 — the code is broken | Scenario 2 — the platform is broken |
| --- | --- | --- |
| **Symptom** | HTTP 500 on product pages | HTTP 503, catalog completely unavailable |
| **Cause** | A latent defect in `src/backend/Program.cs` | A bad `CATALOG_SOURCE` value on the Container App |
| **Agent outcome** | Finds the failing line and **opens a GitHub issue** | **Runs an Azure operation** and the app recovers live |
| **Why not the other way** | No platform change can fix a code defect | The deployed image is correct; there is nothing to file |

The storefront carries a status banner, so the audience watches the app go amber or red and back to
green without reading a single log line.

## Architecture

```
Zava frontend (Container App, public)  ── polls /api/health every 5s ──►  status banner
  │  nginx proxies /api/* ──► Zava backend (Container App, internal)         green / amber / red
  ▼
Backend telemetry (OpenTelemetry, AppRoleName = zava-backend)
  ├─ console logs             ──►  Log Analytics (ContainerAppConsoleLogs_CL)
  └─ logs / traces / metrics  ──►  Application Insights (AppRequests, AppExceptions, AppTraces)
                                       │
             ┌─────────────────────────┴─────────────────────────┐
             ▼                                                   ▼
  alert-zava-app-exception-*                          alert-zava-availability-*
  (AppExceptions > 0)                                 (503 responses > 3)
             │                                                   │
             └──────────────────► Action Group ◄──────────────────┘
                                       │
                                       ▼
                        Azure SRE Agent (Microsoft.App/agents)
                                       │
             ┌─────────────────────────┴─────────────────────────┐
             ▼                                                   ▼
      code-investigator                                  platform-operator
  reads the stack trace, finds file:line          reads Activity Log + revision history,
  in the connected repo, opens a GitHub           restores the Container App config with
  issue. Never touches Azure.                     `az containerapp update`. Never files an issue.
```

Routing is by alert name: the response plan filters match `app-exception` and `availability`, which
is why the two alert names share no other distinguishing substring.

## What is in this repo

| Path | Purpose |
| --- | --- |
| `infra/main.bicep` | Log Analytics, Application Insights, Container Apps environment, Zava backend + frontend, managed identity + RBAC |
| `infra/sre-agent.bicep` | The SRE Agent, its identity and RBAC, the Action Group, and the two scenario alerts |
| `src/backend/` | Zava .NET 10 minimal API — catalog, the promo-rate defect, the `CATALOG_SOURCE` gate, and `/api/health` |
| `src/frontend/` | React + Vite SPA — catalog/basket plus the system status banner |
| `scripts/pre-provision.sh` | Mints a GitHub token via `gh` and auto-detects the repo so Code Access needs no manual steps |
| `scripts/post-provision.sh` | Uploads both runbooks and creates the two subagents and two response plans |
| `scripts/break-app.sh` | Scenario 1 — drives enough traffic through the defect to trip the alert |
| `scripts/break-config.sh` | Scenario 2 — injects the bad Container App configuration |
| `scripts/fix-config.sh` | Scenario 2 — manual reset |
| `azure.yaml` | azd configuration — provisions infra then runs `post-provision.sh` |

## Deploy with one command

### Prerequisites

- Azure CLI + Azure Developer CLI (`azd`)
- `az login` / `azd auth login`
- [GitHub CLI](https://cli.github.com) (`gh`) — used to mint the GitHub token automatically
- Issues enabled on the target repository

### Steps

```bash
azd up
```

That's it. On `azd up` the `preprovision` hook (`scripts/pre-provision.sh`):

1. Signs you into GitHub via `gh` (requesting the `repo` scope) if you aren't already, and stores the token as `GITHUB_PAT` in the azd environment.
2. Auto-detects the target repository from your `origin` remote and stores it as `GITHUB_REPOSITORY`.

Both values are read by `scripts/post-provision.sh`, which connects Code Access over the agent's
data-plane API. GitHub cannot be wired up from Bicep: it is not a valid ARM `dataConnectorType`.

> Prefer to provide your own token? Set it before running `azd up` and the hook will reuse it:
>
> ```bash
> azd env set GITHUB_REPOSITORY "owner/sre-agent-demo"
> azd env set GITHUB_PAT        "ghp_…"   # PAT with Issues: Read + Write
> ```

`azd up` will:

1. Run `infra/main.bicep` → creates all Azure resources including the SRE Agent and both alerts.
2. Build and push the backend and frontend images, then update both Container Apps.
3. Run `scripts/post-provision.sh` → connects Code Access and configures the knowledge base, the two
   subagents, and the two response plans.

## Local development

```bash
# Terminal 1 – .NET backend on :8080
cd src/backend && dotnet run

# Terminal 2 – React dev server on :5173 (proxies /api/* to :8080)
cd src/frontend && npm install && npm run dev
```

Reproduce Scenario 2 locally by starting the backend with `CATALOG_SOURCE=cosmosdb-prod dotnet run`.

## Running the demo

Open the storefront URL printed by `azd up`. The banner should read **ALL SYSTEMS OPERATIONAL**.

### Scenario 1 — troubleshoot and open a GitHub issue

The defect ships in the image and only fires on one catalog category, so nothing needs to be broken
first. Click a **Small** pets product in the storefront, or drive enough traffic to trip the alert:

```bash
bash scripts/break-app.sh
```

The banner turns amber and the product page fails. The agent then:

1. Queries `AppRequests` / `AppExceptions` and finds a `KeyNotFoundException`.
2. Reads the stack frame, which points at the promo-rate lookup in `src/backend/Program.cs`.
3. Opens that file through Code Access and works out that the `Small` category was never added to
   the promo table.
4. Opens a GitHub issue with the evidence and a suggested one-line fix — and changes nothing in Azure.

**Nothing to reset.** The fault lives in source, so the scenario is repeatable as-is.

### Scenario 2 — perform an operation on Azure resources

```bash
bash scripts/break-config.sh
```

This runs `az containerapp update --set-env-vars CATALOG_SOURCE=cosmosdb-prod`. Container Apps rolls
out a new revision, every catalog route starts returning 503, and the banner goes red within a few
seconds. The agent then:

1. Confirms the outage in `AppRequests` and reads the `CONFIG_ERROR` reason from `AppTraces`.
2. Compares the live environment variables against the known-good baseline in its runbook.
3. Correlates the outage with the `Microsoft.App/containerApps/write` entry in the Activity Log.
4. Runs `az containerapp update --set-env-vars CATALOG_SOURCE=builtin` and verifies recovery.

The banner returns to green with no redeploy. Reset manually with `bash scripts/fix-config.sh`.

> Both alerts are log-search rules, so expect roughly 5–10 minutes between the fault and the agent
> picking it up. To drive either scenario on demand, start a chat with the agent and point it at the
> symptom instead of waiting for the alert.

## Notes

- `GITHUB_PAT` is used only by `scripts/post-provision.sh` to configure Code Access over the agent's
  data-plane API. It is not written to disk or logged.
- Telemetry from the backend arrives with `AppRoleName` set to the **Container App name**
  (`ca-zava-backend-<env>`), not the container name — the Container Apps resource detector
  overrides `OTEL_SERVICE_NAME`. Every alert and runbook query therefore matches on
  `AppRoleName startswith "ca-zava-backend"`. Filtering on `"zava-backend"` silently returns
  zero rows and the alerts never fire.
- The agent's data-plane endpoint serves its web UI as a catch-all, so an unknown API path
  returns **HTTP 200 with HTML** rather than 404. `scripts/post-provision.sh` verifies its
  work by reading the configuration back rather than trusting status codes.
- The subagent API accepts unknown tool names silently. The verification step cross-checks
  each granted tool against `GET /api/v2/agent/tools` and reports any phantom grants.
- The alerts set `skipQueryValidation` because `AppExceptions` / `AppRequests` do not exist in a
  brand-new workspace until the app has sent its first telemetry.
- Code Access is connected to this repository, so the agent can also read the break scripts. That is
  accepted: the demonstration is the remediation, not the discovery.
- The `Microsoft.App/agents` resource type is in **public preview**. Verify the Bicep API version and
  the data-plane payload schemas in `scripts/post-provision.sh` against current preview docs.
