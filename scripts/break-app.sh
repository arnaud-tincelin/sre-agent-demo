#!/usr/bin/env bash
# break-app.sh - Scenario 1: exercise the latent code defect.
#
# The defect is always present in the deployed image; it only triggers on product
# pages in one catalog category. Clicking one of those products in the storefront
# is enough to see the HTTP 500, but the alert needs a few failures in its
# evaluation window - this generates them.
#
# There is nothing to reset: the fault lives in source, not in configuration.

set -euo pipefail

REQUESTS="${REQUESTS:-10}"

source "$(dirname "$0")/_demo-env.sh"

echo "==> Requesting affected product pages ${REQUESTS}x via ${FRONTEND_URL}"

for id in $(seq 1 "${REQUESTS}"); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "${FRONTEND_URL}/api/catalog/$(( 18 + id % 3 ))")
  echo "  request ${id}: HTTP ${code}"
done

echo
echo "The storefront banner turns amber. The '${APP_EXCEPTION_ALERT}' alert fires"
echo "within about 5-10 minutes and the code-investigator subagent opens a GitHub issue."