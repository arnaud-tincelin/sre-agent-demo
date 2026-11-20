#!/usr/bin/env bash
# break-app.sh - Scenario 1: exercise the code defect on a pre-fix deployment.
#
# On an affected revision, the defect only triggers on product
# pages in one catalog category. Clicking one of those products in the storefront
# is enough to see the HTTP 500, but the alert needs a few failures in its
# evaluation window - this generates them.
#
# Redeploy the current version to restore the affected product pages.

set -euo pipefail

REQUESTS="${REQUESTS:-10}"

source "$(dirname "$0")/_demo-env.sh"

echo "==> Requesting affected product pages ${REQUESTS}x via ${FRONTEND_URL}"

for id in $(seq 1 "${REQUESTS}"); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "${FRONTEND_URL}/api/catalog/$(( 18 + id % 3 ))")
  echo "  request ${id}: HTTP ${code}"
done

echo
echo "On an affected revision, HTTP 500 responses turn the banner amber and can trigger"
echo "the '${APP_EXCEPTION_ALERT}' alert within about 5-10 minutes."