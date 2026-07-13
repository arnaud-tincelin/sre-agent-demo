# Zava environment

Reference facts about the deployed environment. Not scenario-specific.

## Topology

| Component | Resource | Notes |
| --- | --- | --- |
| Storefront UI | Container App `ca-zava-frontend-<env>` | External ingress. nginx serves the React SPA and proxies `/api/*` to the backend. |
| Backend API | Container App `ca-zava-backend-<env>` | Internal ingress only, port 8080. Container name is `zava-backend`. |
| Telemetry | Application Insights `appi-<env>` → Log Analytics `law-<env>` | Workspace-based. |
| Registry | `acr*` | Holds both images. |
| Incidents | Action group `ag-sre-agent-<env>` | Azure Monitor alerts dispatch here. |

Both container apps run at 1 replica, single revision mode.

## Backend endpoints

| Route | Behaviour |
| --- | --- |
| `GET /api/catalog` | Lists 20 products across 5 categories: Dogs, Cats, Birds, Fish, Small. |
| `GET /api/catalog/{id}` | Product detail. |
| `GET /api/health` | Storefront health. Returns 200 with `status: healthy`, or 503 with `status: unhealthy` and a `reason` when misconfigured. The UI polls this every 5 seconds. |
| `GET /healthz` | Flat 200 platform probe. Stays 200 even when the app is misconfigured, so a config fault does not restart the container. |

## Configuration

The backend reads its catalog provider from the `CATALOG_SOURCE` environment variable,
supplied by the Container App configuration.

**Known-good value: `CATALOG_SOURCE=builtin`.** It is the only provider this build
implements. Any other value makes every `/api/catalog*` route return HTTP 503.

Read the live value with:

```bash
az containerapp show -g <RG> -n <BACKEND_APP> --query "properties.template.containers[0].env" -o table
```

## Alerts

| Alert | Fires on | Meaning |
| --- | --- | --- |
| `alert-zava-app-exception-<env>` | Any row in `AppExceptions` | Code defect. Customers see HTTP 500. |
| `alert-zava-availability-<env>` | More than 3 HTTP 503 responses in `AppRequests` | Platform fault. The catalog is down. |

Both are log-search rules on a 5-minute window evaluated every 5 minutes, so expect a few
minutes between the fault starting and the incident arriving.

## Querying telemetry

`AppRoleName` is the Container App name, not the container name. Use
`AppRoleName startswith "ca-zava-backend"` in every query against `AppRequests`,
`AppExceptions`, `AppTraces`, and `AppMetrics`.
