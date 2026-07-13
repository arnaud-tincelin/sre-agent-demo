# sre-agent-demo

Demo environment for an Azure SRE Agent with a buggy e-commerce app named **Zava**.

## What this demo contains

- **Zava web app** (Azure Container Apps):
  - Catalog for pet products
  - Basket to add products
  - Intentional memory leak function: `AVeryMemoryIntensiveFunction`
- **SRE agent service** (Azure Container Apps):
  - Detects OOM symptoms and root-cause marker from Log Analytics
  - Mitigates by scaling the Zava Container App (`maxReplicas` increase)
  - Opens a GitHub issue in this repository

## Deploy everything with one command

Prerequisites:
- Azure CLI + Azure Developer CLI (`azd`)
- Logged in to Azure (`az login`)
- Optional: a GitHub token with `repo` scope to open issues

```bash
export GITHUB_TOKEN=<your-token>   # optional but required for issue creation
azd up
```

This provisions infrastructure with **Bicep** (`/infra`) and deploys both services.

## Demo flow

1. Browse the Zava URL from `azd up` output.
2. Navigate between catalog and basket repeatedly.
3. The app keeps calling `AVeryMemoryIntensiveFunction` on navigation and leaks memory.
4. The SRE agent detects OOM/root-cause patterns in logs.
5. The SRE agent scales ACA replicas and opens a GitHub issue.

## Repository layout

- `/infra/main.bicep`: Log Analytics + Container Apps environment
- `/src/web`: Zava e-commerce app (with intentional memory bug)
- `/src/sre-agent`: SRE agent implementation
- `/scripts/configure-agent-identity.sh`: post-deploy identity + RBAC setup
