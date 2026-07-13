from __future__ import annotations

import json
import os
import time
from datetime import datetime, timezone

import requests
from azure.identity import DefaultAzureCredential

SUBSCRIPTION_ID = os.getenv("SUBSCRIPTION_ID", "")
RESOURCE_GROUP = os.getenv("RESOURCE_GROUP", "")
TARGET_CONTAINER_APP = os.getenv("TARGET_CONTAINER_APP", "zava-web")
TARGET_MAX_REPLICAS = int(os.getenv("TARGET_MAX_REPLICAS", "4"))
WORKSPACE_ID = os.getenv("LOG_ANALYTICS_WORKSPACE_ID", "")
POLL_INTERVAL_SECONDS = int(os.getenv("POLL_INTERVAL_SECONDS", "60"))
GITHUB_REPOSITORY = os.getenv("GITHUB_REPOSITORY", "")
GITHUB_TOKEN = os.getenv("GITHUB_TOKEN", "")

credential = DefaultAzureCredential(exclude_interactive_browser_credential=True)
issue_already_opened = False


def _token(scope: str) -> str:
    return credential.get_token(scope).token


def detect_issue() -> bool:
    if not WORKSPACE_ID:
        print("LOG_ANALYTICS_WORKSPACE_ID is missing; detection skipped.")
        return False

    query = """
search in (ContainerAppConsoleLogs, ContainerAppConsoleLogs_CL, ContainerAppSystemLogs, ContainerAppSystemLogs_CL)
  "AVeryMemoryIntensiveFunction" or "OOMKilled" or "OutOfMemory"
| where TimeGenerated > ago(15m)
| top 10 by TimeGenerated desc
"""

    token = _token("https://api.loganalytics.azure.com/.default")
    response = requests.post(
        f"https://api.loganalytics.azure.com/v1/workspaces/{WORKSPACE_ID}/query",
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
        json={"query": query},
        timeout=30,
    )
    response.raise_for_status()

    tables = response.json().get("tables", [])
    issue_detected = any(table.get("rows") for table in tables)
    if issue_detected:
        print("Detected OOM-related logs and root cause marker AVeryMemoryIntensiveFunction.")
    return issue_detected


def scale_container_app() -> None:
    if not SUBSCRIPTION_ID or not RESOURCE_GROUP:
        print("Subscription/resource group missing; cannot scale deployment.")
        return

    app_id = (
        f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RESOURCE_GROUP}"
        f"/providers/Microsoft.App/containerApps/{TARGET_CONTAINER_APP}"
    )
    url = f"https://management.azure.com{app_id}?api-version=2024-03-01"
    token = _token("https://management.azure.com/.default")
    headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}

    current = requests.get(url, headers=headers, timeout=30)
    current.raise_for_status()
    payload = current.json()

    payload.setdefault("properties", {}).setdefault("template", {}).setdefault("scale", {})
    payload["properties"]["template"]["scale"]["maxReplicas"] = TARGET_MAX_REPLICAS
    payload["properties"]["template"]["scale"]["minReplicas"] = 1

    update = requests.put(url, headers=headers, data=json.dumps(payload), timeout=30)
    update.raise_for_status()
    print(f"Scaled {TARGET_CONTAINER_APP} to maxReplicas={TARGET_MAX_REPLICAS}.")


def open_issue() -> None:
    global issue_already_opened

    if issue_already_opened:
        return

    if not GITHUB_TOKEN or not GITHUB_REPOSITORY:
        print("GitHub configuration is missing; issue creation skipped.")
        return

    title = "[SRE Agent] OOM in AVeryMemoryIntensiveFunction mitigated by ACA scale-out"
    body = (
        "The Azure SRE agent detected OOM symptoms while navigating Zava and identified "
        "`AVeryMemoryIntensiveFunction` as the likely root cause.\n\n"
        f"Mitigation applied at {datetime.now(timezone.utc).isoformat()}:\n"
        f"- Container App: `{TARGET_CONTAINER_APP}`\n"
        f"- Action: scale max replicas to `{TARGET_MAX_REPLICAS}`\n\n"
        "Please prioritize a code fix for the memory-intensive function."
    )

    response = requests.post(
        f"https://api.github.com/repos/{GITHUB_REPOSITORY}/issues",
        headers={
            "Authorization": "Bearer " + GITHUB_TOKEN,
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        json={"title": title, "body": body, "labels": ["bug", "sre-agent"]},
        timeout=30,
    )
    response.raise_for_status()
    issue_number = response.json().get("number")
    print(f"Opened GitHub issue #{issue_number}.")
    issue_already_opened = True


def main() -> None:
    print("Azure SRE Agent demo started")
    while True:
        try:
            if detect_issue():
                scale_container_app()
                open_issue()
        except Exception as exc:  # demo resiliency
            print(f"SRE agent loop error: {exc}")

        time.sleep(POLL_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
