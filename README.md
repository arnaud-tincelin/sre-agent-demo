# sre-agent-demo

An Azure SRE Agent operating a small e-commerce storefront called **Zava**, with two break/fix
scenarios you can run in front of an audience.

|                         | Scenario 1                                          | Scenario 2                                            |
| ----------------------- | --------------------------------------------------- | ----------------------------------------------------- |
| **What breaks**         | A code defect — HTTP 500 on some product pages      | A bad config value — HTTP 503, catalog down           |
| **What the agent does** | Finds the failing line and **opens a GitHub issue** | **Runs an Azure operation** and the app recovers live |

The storefront carries a status banner, so the audience watches it go amber or red and back to
green without reading a single log line.

https://github.com/user-attachments/assets/df5ab204-db9d-4c69-aa00-3df2d5caf9d7

## 1. Prerequisites

- Azure CLI and Azure Developer CLI, both signed in (`az login` **and** `azd auth login`)
- [GitHub CLI](https://cli.github.com) (`gh`)
- A GitHub repository you can push to, with Issues enabled
- **Push your branch before deploying.** The agent reads source from the branch you deploy
  from, so it has to exist on the remote for Scenario 1 to cite real code.

## 2. Deploy

```bash
azd up
```

About 5 minutes. It provisions Azure, builds and deploys both containers, then configures the
agent. GitHub sign-in happens automatically; to supply your own token instead:

```bash
azd env set GITHUB_REPOSITORY "owner/repo"
azd env set GITHUB_PAT        "ghp_…"   # needs Issues: Read + Write
```

## 3. Open the storefront

Browse to the URL `azd up` printed. The banner should read **ALL SYSTEMS OPERATIONAL**.

## 4. Scenario 1 — troubleshoot and file a GitHub issue

The defect already ships in the app and only fires on the **Small** pets category. Click one of
those products, or generate enough failures to trip the alert:

```bash
bash scripts/break-app.sh
```

The banner turns amber. Watch the agent at [sre.azure.com](https://sre.azure.com) under
Activities → Incidents: it queries the telemetry, follows the stack trace into `Program.cs`,
and opens a GitHub issue naming the exact line — without touching any Azure resource.

Nothing to reset. The fault lives in source, so the scenario repeats as-is.

## 5. Scenario 2 — fix an Azure resource

```bash
bash scripts/break-config.sh
```

The banner goes red within about 30 seconds and the catalog returns 503. The agent confirms the
outage, correlates it with the configuration change in the Activity Log, restores the setting
with `az containerapp update`, and verifies recovery. The banner returns to green with no
redeploy.

To reset it yourself:

```bash
bash scripts/fix-config.sh
```

## Timing

Both alerts are log-search rules, so allow **5–10 minutes** between breaking something and the
agent picking it up. To skip the wait, open a chat with the agent and describe the symptom.

## Tear down

```bash
azd down --purge
```

## Optional: run locally

```bash
cd src/backend  && dotnet run                    # :8080
cd src/frontend && npm install && npm run dev    # :5173
```

Start the backend with `CATALOG_SOURCE=cosmosdb-prod dotnet run` to reproduce Scenario 2.

## Changing what the agent does

Everything the agent reads at runtime — instructions, knowledge base, skills, subagent prompts,
and alert routing — lives in [sre-config/](sre-config). Edit it and re-run
`bash scripts/post-provision.sh`; no redeploy needed.

Working on the Bicep or the scripts? [AGENTS.md](AGENTS.md) covers the non-obvious behaviour.
