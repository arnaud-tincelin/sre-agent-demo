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

### Prerequisites for this demo

The demo uses **GitHub** for source access and issue creation; Azure DevOps is not required.
Both deployment options create the hosting resource group, demo workload, Application Insights,
Log Analytics workspace, and a new user-assigned managed identity (UAMI) for the agent.

| Area | Prerequisite |
| --- | --- |
| **Azure environment** | An active subscription and a region where Azure SRE Agent and the configured model provider are available. The templates select **Anthropic / Automatic**; East US 2 was used for this demo. No pre-existing hosting RG is required. |
| **Deployer permissions** | **Owner**, or **Contributor + User Access Administrator**, at subscription scope for the included deployments, which create the RG and assign roles. RG-scoped permissions alone do not authorize creating a new RG. Activate eligible **PIM** roles before deployment. |
| **GitHub access** | A repository you can push to, with Issues enabled. The credential used by the agent must allow repository contents to be read and issues to be created; for a fine-grained PAT, use **Contents: Read** and **Issues: Read and write**. |

Install the following tools:

- Azure CLI and Azure Developer CLI, both signed in (`az login` **and** `azd auth login`)
- Bash, `curl`, and `jq` for the shared provisioning hooks (also on Windows, using Git Bash)
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.5 or later for the Terraform option
- [GitHub CLI](https://cli.github.com) (`gh`)

**Push your branch before deploying.** The agent reads source from the branch you deploy
from, so it has to exist on the remote for Scenario 1 to cite real code.

### Permissions assigned automatically

Both Bicep and Terraform explicitly create these role assignments:

| Recipient | Assignment | Scope |
| --- | --- | --- |
| **Deployment identity** | **SRE Agent Administrator**, so the provisioning hook can configure the agent | New agent resource only |
| **Agent UAMI - workload visibility** | **Reader**, **Monitoring Reader**, and **Log Analytics Reader** | Demo RG |
| **Agent UAMI - telemetry configuration** | **Log Analytics Contributor** and **Application Insights Component Contributor** | Demo RG |
| **Agent UAMI - remediation** | **Container Apps Contributor**, enabling Scenario 2 to repair the backend configuration | Demo RG |
| **Container Apps UAMI** | **AcrPull**, allowing both apps to pull deployed images | Demo container registry |

Azure **Owner** and **Contributor** alone do **not** grant SRE Agent data-plane permissions.
The portal creation flow automatically assigns its creator **SRE Agent Administrator**;
IaC must declare that assignment explicitly, as these templates do. For other engineers,
assign **SRE Agent Standard User** on the agent for chat and diagnostics, or **SRE Agent
Administrator** when configuration changes or action approval are required.

This is a **privileged, autonomous demo**, not a read-only deployment. Write access is optional
for initial read-only investigations in a general SRE Agent setup, but Scenario 2 requires
Container Apps write access. For a read-only setup, start with Reader-level access and review
any additional resource-specific roles proposed by setup.

When connecting existing workload or telemetry resources outside the demo RG, identify their
scopes and grant the agent UAMI the required roles there. For connected Application Insights
resources and Log Analytics workspaces, including central workspaces, setup assigns
**Log Analytics Reader** and **Monitoring Reader**; inherited assignments may already cover
access. Where new assignments are needed, the configuring administrator needs **Owner** or
**User Access Administrator** at each target scope. Portal role-assignment deployments can
also require `Microsoft.Resources/deployments/write`. If adapting the templates to reuse an
existing UAMI, permission to attach it is required, such as **Managed Identity Operator** on
that identity.

**Optional alert lifecycle management:** acknowledging or closing Azure Monitor alerts needs
additional monitoring write permissions. The verified built-in role is **Monitoring
Contributor** (`749f88d5-cbae-40b8-bcfc-e573ddc772fa`), which grants broader monitoring writes
than alert acknowledgement alone. Review its definition and intended scope before granting
it; do not assume a differently named role is equivalent. These templates do not assign
subscription-wide Monitoring Contributor.

### Optional: Azure DevOps via managed identity

Azure DevOps is **not configured by this demo's provisioning hooks**. For an agent investigating
Azure Repos, prepare the following before connecting repositories through the agent portal:

| Area | Prerequisite |
| --- | --- |
| **Tenant** | The Azure DevOps organization must be connected to the same Entra tenant as the managed identity used for the connection. |
| **Organization membership** | An authorized ADO administrator must explicitly add the managed identity to the organization. Use its service principal object/principal ID, not its client ID. |
| **Access level** | Assign **Basic** access or higher; Stakeholder access does not provide Azure Repos access. |
| **Repository permissions** | Grant project visibility and **Read** on the selected repositories. Code investigation does not require repository-write or ADO administrator permissions for the identity. |

**Azure RBAC does not grant ADO repository access.** ADO membership, access level, and repository
permissions are separate. The existing GitHub provisioning hooks do not become an ADO
integration by changing `GITHUB_REPOSITORY`.

Sources: [Deployment and setup](https://sre.azure.com/docs/get-started/create-and-setup) ·
[User roles](https://sre.azure.com/docs/concepts/user-roles) ·
[Agent permissions](https://sre.azure.com/docs/concepts/permissions) ·
[Monitoring Contributor](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/monitor#monitoring-contributor) ·
[ADO managed identity setup](https://learn.microsoft.com/azure/sre-agent/connect-ado-repo-managed-identity).

## 2. Deploy

Choose one azd project. Both provision the same demo and configure the agent from
the shared `sre-config/` directory; application source and provisioning scripts are shared too.

| Infrastructure | Project directory | Deploy from the repository root |
| --- | --- | --- |
| Bicep | `bicep/` | `azd up --cwd bicep` |
| Terraform | `terraform/` | `azd up --cwd terraform` |

For example, to deploy with Terraform:

```bash
cd terraform
azd env new my-tf-demo
azd up
```

For Bicep, use `cd bicep` instead. Use different environment names when deploying both
options side by side; they must not manage the same resources. Running `azd up` at the
repository root remains a backwards-compatible Bicep entry point.

About 5 minutes. It provisions Azure, builds and deploys both containers, then configures the
agent. GitHub sign-in happens automatically; to supply your own token instead:

```bash
azd env set GITHUB_REPOSITORY "owner/repo"
azd env set GITHUB_PAT        "ghp_…"   # Contents: Read; Issues: Read + Write
```

Run environment commands from your chosen project directory (or pass `--cwd bicep` /
`--cwd terraform`). Each project keeps its own azd environments in `.azure/`.
Terraform state is local to that environment under `terraform/.azure/<environment>/infra/`;
keep it safe to update or destroy that deployment. It can contain sensitive values and must
not be committed. For team use, configure a shared Terraform backend before provisioning.
Terraform ignores only the container image fields managed by `azd deploy`, so re-running
`azd provision` does not replace deployed images with the initial placeholder.

## 3. Open the storefront

Browse to the URL `azd up` printed. The banner should read **ALL SYSTEMS OPERATIONAL**.

## 4. Scenario 1 — troubleshoot and file a GitHub issue

The defect already ships in the app and only fires on the **Small** pets category. Click one of
those products, or generate enough failures to trip the alert:

```bash
bash ../scripts/break-app.sh
```

The banner turns amber. Watch the agent at [sre.azure.com](https://sre.azure.com) under
Activities → Incidents: it queries the telemetry, follows the stack trace into `Program.cs`,
and opens a GitHub issue naming the exact line — without touching any Azure resource.

Nothing to reset. The fault lives in source, so the scenario repeats as-is.

## 5. Scenario 2 — fix an Azure resource

```bash
bash ../scripts/break-config.sh
```

The banner goes red within about 30 seconds and the catalog returns 503. The agent confirms the
outage, correlates it with the configuration change in the Activity Log, restores the setting
with `az containerapp update`, and verifies recovery. The banner returns to green with no
redeploy.

To reset it yourself:

```bash
bash ../scripts/fix-config.sh
```

## Timing

Both alerts are log-search rules, so allow **5–10 minutes** between breaking something and the
agent picking it up. To skip the wait, open a chat with the agent and describe the symptom.

## Tear down

```bash
azd down --purge
```

Run this in the same project directory and environment that created the resources.

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

From the chosen deployment directory, load its environment before applying configuration:

```bash
set -a
eval "$(azd env get-values)"
set +a
bash ../scripts/post-provision.sh
```

Working on the Bicep or the scripts? [AGENTS.md](AGENTS.md) covers the non-obvious behaviour.
