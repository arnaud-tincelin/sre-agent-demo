---
name: diagnose-zava-app-exception
description: Load this skill when the Zava storefront returns HTTP 500, when an alert whose name contains "app-exception" fires, or when unhandled exceptions appear in AppExceptions for the Zava backend. Provides the query sequence for correlating a failing request to the exact source line, and the rules for reporting the defect. Do not load it for HTTP 503 or availability incidents.
---

# Diagnose a Zava application exception

Customers see HTTP 500 on a storefront route and the backend is recording unhandled
exceptions. This is a code defect. It is not remediable from the Azure control plane.

## 1. Establish blast radius

```kusto
AppRequests
| where AppRoleName startswith "ca-zava-backend"
| summarize Total = count(), Failed = countif(ResultCode == "500") by Name, bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

Record which routes fail, which still succeed, and the failure rate. A defect scoped to one
route is a much stronger signal than a whole-service outage.

## 2. Retrieve the exception and its stack trace

```kusto
AppExceptions
| where AppRoleName startswith "ca-zava-backend"
| project TimeGenerated, ProblemId, OuterType, OuterMessage, Details, OperationId
| order by TimeGenerated desc
| take 20
```

`Details` carries the parsed stack trace including the source file and line number. The
exception message frequently names the offending value directly — read it carefully before
inferring anything.

## 3. Correlate a specific failing request

```kusto
AppRequests
| where AppRoleName startswith "ca-zava-backend" and ResultCode == "500"
| join kind=inner (AppExceptions | where AppRoleName startswith "ca-zava-backend") on OperationId
| project TimeGenerated, Name, Url, OuterType, OuterMessage, Details
| order by TimeGenerated desc
```

This ties a customer-visible URL to the exception it produced.

## 4. Read the source

Use `FindConnectedGitHubRepo`, then `ListDir`, `GrepSearch`, and `ReadFile` to open the file
named in the stack frame. Read the surrounding code and identify the exact statement that
throws and the input that triggers it.

If the file or line is missing from the connected branch, say so explicitly and report the
stack frame instead of guessing. Do not invent code you have not read.

## 5. Report

Do not scale, restart, roll back, or reconfigure anything. There is no platform fix for a
code defect, and mutating the app destroys the evidence.

File a GitHub issue titled `[SRE] HTTP 500 on <route> - <ExceptionType>` containing:

- Alert name and firing time
- Customer-visible symptom and how to reproduce it from the storefront
- Exception type and message
- The stack frame with `file:line`
- The offending code, quoted from the repository
- Affected request count and time window
- A concrete, minimal suggested fix
- An explicit statement that no Azure resource was modified

Finish by summarising the investigation in the incident thread and linking the issue.
