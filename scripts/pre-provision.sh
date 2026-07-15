#!/usr/bin/env sh
# pre-provision.sh – Make `azd up` a true one-command experience for the
# SRE Agent ↔ GitHub connection.
#
# Wired into azd via the `preprovision` hook in azure.yaml. It runs *before*
# infra/main.bicep and persists values with `azd env set`, so the Bicep
# `githubPat` / `githubRepository` parameters are populated automatically
# (see infra/main.parameters.json).
#
# GitHub does not allow minting a classic PAT non-interactively, so this uses
# the GitHub CLI (`gh`) OAuth session to obtain a usable token. If gh is not
# available and no token is set, provisioning continues without the connector.

set -eu

# Never trace – avoid leaking the token into logs.
set +x

echo "==> Preparing GitHub connection for the SRE Agent..."

# ── 1. Already configured? ────────────────────────────────────────────────────
if [ -n "${GITHUB_PAT:-}" ]; then
  echo "  GITHUB_PAT already set – reusing it."
else
  # ── 2. Need the GitHub CLI to mint a token ──────────────────────────────────
  if ! command -v gh >/dev/null 2>&1; then
    echo "  WARNING: GitHub CLI (gh) is not installed and GITHUB_PAT is not set."
    echo "           The SRE Agent GitHub connector will be skipped."
    echo "           To enable it, either:"
    echo "             - install gh (https://cli.github.com) and re-run 'azd up', or"
    echo "             - run: azd env set GITHUB_PAT <token>"
    exit 0
  fi

  # ── 3. Ensure gh is authenticated with the 'repo' scope (needed for issues) ─
  if ! gh auth status >/dev/null 2>&1; then
    echo "  Launching GitHub login (needs 'repo' scope so the agent can open issues)..."
    gh auth login --scopes repo
  elif ! gh auth status 2>&1 | grep -q "'repo'"; then
    echo "  Adding 'repo' scope to the existing GitHub session..."
    gh auth refresh --scopes repo
  fi

  # ── 4. Grab the token and persist it into the azd environment ──────────────
  TOKEN="$(gh auth token 2>/dev/null || true)"
  if [ -z "${TOKEN}" ]; then
    echo "  WARNING: Could not obtain a GitHub token from gh. Skipping connector."
    exit 0
  fi
  azd env set GITHUB_PAT "${TOKEN}"
  echo "  Stored GitHub token in the azd environment (GITHUB_PAT)."
fi

# ── 5. Derive the repository if not already set ───────────────────────────────
if [ -z "${GITHUB_REPOSITORY:-}" ]; then
  REPO=""
  if command -v gh >/dev/null 2>&1; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  if [ -z "${REPO}" ] && command -v git >/dev/null 2>&1; then
    # Fallback: parse origin (git@github.com:owner/repo.git or https://github.com/owner/repo.git)
    ORIGIN="$(git config --get remote.origin.url 2>/dev/null || true)"
    REPO="$(printf '%s' "${ORIGIN}" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
  fi
  if [ -n "${REPO}" ]; then
    azd env set GITHUB_REPOSITORY "${REPO}"
    echo "  Detected repository: ${REPO}"
  else
    echo "  NOTE: GITHUB_REPOSITORY not set and could not be auto-detected."
    echo "        Set it with: azd env set GITHUB_REPOSITORY <owner/repo>"
  fi
fi

echo "==> GitHub connection ready."
