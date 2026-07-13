---
name: repair-zava-catalog-config
description: Load this skill when the Zava storefront catalog is unavailable, when an alert whose name contains "availability" fires, or when the Zava backend returns HTTP 503 with CONFIG_ERROR in its traces. Provides the sequence for confirming a configuration fault, correlating it to the change that caused it, and repairing the Container App. Do not load it for HTTP 500 or unhandled exception incidents.
---

# Repair the Zava catalog configuration

The storefront catalog is returning HTTP 503. This is a platform configuration fault. The
deployed image is correct, so there is nothing to fix in code.

## 1. Confirm the outage and when it started

```kusto
AppRequests
| where AppRoleName startswith "ca-zava-backend"
| summarize Requests = count(), Unavailable = countif(ResultCode == "503") by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

## 2. Read the reason the app is reporting

The backend logs why it is refusing requests, on every failed request:

```kusto
AppTraces
| where AppRoleName startswith "ca-zava-backend"
| where Message has "CONFIG_ERROR"
| order by TimeGenerated desc
| take 20
```

Absence of exceptions alongside these 503s is what distinguishes a configuration fault from
a code defect. If you find unhandled exceptions instead, stop and use the application
exception skill.

## 3. Compare live configuration against the baseline

```bash
az containerapp show -g <RG> -n <BACKEND_APP> --query "properties.template.containers[0].env" -o table
```

The known-good value is in the environment knowledge file: `CATALOG_SOURCE=builtin`. Any
other value takes the catalog down.

## 4. Correlate with the change that caused it

```bash
az containerapp revision list -g <RG> -n <BACKEND_APP> \
  --query "[].{name:name, created:properties.createdTime, active:properties.active, traffic:properties.trafficWeight}" -o table
```

```bash
az monitor activity-log list -g <RG> --offset 6h \
  --query "[?contains(operationName.value, 'Microsoft.App/containerApps/write')].{time:eventTimestamp, caller:caller, status:status.value}" -o table
```

A new revision created at the moment the 503s began identifies the change. Name the caller
and the timestamp in your report.

## 5. Remediate

```bash
az containerapp update -g <RG> -n <BACKEND_APP> --set-env-vars CATALOG_SOURCE=builtin
```

Do not open a GitHub issue and do not request a code change for this incident.

## 6. Verify recovery

1. Re-read the environment variables and confirm `CATALOG_SOURCE=builtin`.
2. Confirm the new revision reaches a healthy running state with 100% of traffic.
3. Confirm `/api/health` returns HTTP 200 with `status: healthy`.
4. Re-run the query from step 1 and confirm `Unavailable` has returned to zero.

Recovery takes roughly 30 seconds after the update, because a new revision has to start and
take traffic. Verify rather than assuming.

Post a resolution summary in the incident thread: what broke, when, the change that caused
it, the command you ran, and the evidence that the storefront recovered.
