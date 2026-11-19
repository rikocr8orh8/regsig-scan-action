#!/usr/bin/env bash
# Calls POST /api/v1/scan in deterministic mode (no model call, no scan quota) and writes a job summary.
# Env: RS_API_KEY, RS_REPO_URL, RS_API_URL, RS_FAIL ("true" = exit 1 on findings). Needs curl and jq.
set -uo pipefail
: "${RS_API_KEY:?api-key is required}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
OUT="${GITHUB_OUTPUT:-/dev/null}"
body=$(jq -n --arg u "$RS_REPO_URL" '{repoUrl:$u, mode:"deterministic"}')
resp=$(mktemp)
code=$(curl -sS -o "$resp" -w '%{http_code}' --max-time 150 -X POST "${RS_API_URL%/}/api/v1/scan" \
  -H "Content-Type: application/json" -H "X-RegulatorySignals-Key: $RS_API_KEY" --data "$body") || code="000"
if [ "$code" != "200" ]; then
  msg=$(jq -r '.error // empty' "$resp" 2>/dev/null | head -c 300)
  echo "::warning::Regulatory Signals check did not run (HTTP $code). ${msg}"
  { echo "### Regulatory Signals check"; echo; echo "Did not run: HTTP $code. ${msg}"; } >> "$SUMMARY"
  echo "findings=0" >> "$OUT"
  exit 0   # a service or key problem never breaks your build; only real findings do, and only with fail-on-findings
fi
findings=$(jq '[ (.checks.resOkViolationCount > 0), (.checks.webhookSilentSuccess == true), (.checks.buttonRouteGapCount > 0),
                 (.checks.paymentWebhookVerified == false), (.checks.stripeWebhookVerified == false) ] | map(select(.)) | length' "$resp")
{
  echo "### Regulatory Signals check"
  echo
  echo "Repository: \`$RS_REPO_URL\` (default branch, deterministic checks)"
  echo
  echo "| Check | Result |"
  echo "|---|---|"
  jq -r '.checks | "| Rate limiting detected | \(.hasRateLimiting) |\n| Unchecked fetch() responses | \(.resOkViolationCount) |\n| Webhook silent success | \(.webhookSilentSuccess) |\n| Payment webhook verified | \(.paymentWebhookVerified // "n/a") |\n| Stripe webhook verified | \(.stripeWebhookVerified // "n/a") |\n| Button-to-route gaps | \(.buttonRouteGapCount) |\n| Row-level security enabled | \(.rlsTablesEnabled) |\n| AI providers | \((.aiProviders // []) | join(", ") | if . == "" then "none" else . end) |"' "$resp"
  echo
  echo "Checks reporting a problem: **$findings**. Powered by [Regulatory Signals](https://www.regulatorysignals.com)."
} >> "$SUMMARY"
echo "findings=$findings" >> "$OUT"
if [ "${RS_FAIL:-false}" = "true" ] && [ "$findings" -gt 0 ]; then
  echo "::error::Regulatory Signals: $findings check(s) reported a problem."
  exit 1
fi
exit 0
