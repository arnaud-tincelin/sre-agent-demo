# Zava operations — global instructions

Zava is an e-commerce storefront running on Azure Container Apps. These instructions apply
to every investigation in this environment.

## Telemetry facts

Application telemetry flows from the backend through OpenTelemetry into Application
Insights, which is workspace-based and writes to the `law-*` Log Analytics workspace
(`AppRequests`, `AppExceptions`, `AppTraces`, `AppMetrics`).

`AppRoleName` is the **Container App name** (`ca-zava-backend-<env>`), not the container
name and not the OpenTelemetry service name — the Container Apps resource detector
overrides both. Always match with:

```kusto
| where AppRoleName startswith "ca-zava-backend"
```

An equality match on `"zava-backend"` returns zero rows and reports a healthy system, which
is wrong. Container console output is separate and *does* key on the container name
(`ContainerAppConsoleLogs_CL | where ContainerName_s == "zava-backend"`).

## Two fault classes, never remediated the same way

Classify the incident before taking any action.

| Symptom | Class | Correct response |
| --- | --- | --- |
| HTTP 500, unhandled exception in `AppExceptions` | Code defect | File a GitHub issue with a `file:line` root cause. No platform change can fix it. |
| HTTP 503, no exception, `CONFIG_ERROR` in `AppTraces` | Platform fault | Repair the Container App configuration. The deployed image is correct; do not request a code change. |

Applying the wrong remediation is worse than doing nothing: restarting or scaling an app
that has a code defect destroys the evidence and does not fix the fault.

If the symptom fits neither class, investigate and report rather than guessing at a fix.

## Evidence standards

State root cause as a specific artifact — a `file:line`, an environment variable value, or a
named change in the Activity Log. "The service is unhealthy" is a symptom, not a cause.
Always report the time window and the number of affected requests.
