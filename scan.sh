#!/usr/bin/env bash
# Calls POST /api/v1/scan in deterministic mode (no model call, no scan quota) and writes a job summary.
# Env: RS_API_KEY, RS_REPO_URL, RS_API_URL, RS_FAIL ("true" = exit 1 on findings).
# Optional env (tests): RS_MAX_TIME (seconds per attempt, default 150), RS_ATTEMPTS (default 3), RS_RETRY_DELAY (seconds, default 3).
# Needs bash, curl and jq.
set -uo pipefail

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
OUT="${GITHUB_OUTPUT:-/dev/null}"
DEFAULT_API_URL="https://www.regulatorysignals.com"

# One line, no control characters, bounded length: safe inside "::warning::" and Markdown.
clean() { printf '%s' "$1" | LC_ALL=C tr '\000-\037\177' ' ' | LC_ALL=C tr -d '`<>' | cut -c1-"${2:-300}"; }

# A service, key or input problem never breaks your build. Only real findings do, and only with fail-on-findings.
did_not_run() { # reason
  local why; why=$(clean "$1")
  echo "::warning::Regulatory Signals check did not run. ${why}"
  { echo "### Regulatory Signals check"; echo; echo "Did not run. ${why}"; } >> "$SUMMARY"
  echo "findings=0" >> "$OUT"
  exit 0
}

command -v curl >/dev/null 2>&1 || did_not_run "curl is not installed on this runner."
command -v jq >/dev/null 2>&1 || did_not_run "jq is not installed on this runner."

[ -n "${RS_API_KEY:-}" ] || did_not_run "No API key was provided (api-key is empty). This is expected on pull requests from forks, where secrets are not passed."
RS_API_URL="${RS_API_URL:-$DEFAULT_API_URL}"
RS_API_URL="${RS_API_URL%/}"
case "$RS_API_URL" in
  https://*|http://127.0.0.1|http://127.0.0.1:*|http://localhost|http://localhost:*) ;;
  *) did_not_run "api-url must start with https:// (plain http is only allowed for localhost). The key was not sent." ;;
esac
[ -n "${RS_REPO_URL:-}" ] || did_not_run "No repository URL was provided."

fail_flag=$(printf '%s' "${RS_FAIL:-false}" | tr '[:upper:]' '[:lower:]')
case "$fail_flag" in true|false|"") ;; *) echo "::warning::fail-on-findings must be 'true' or 'false' (got '$(clean "$RS_FAIL" 20)'); treating it as 'false'."; fail_flag=false ;; esac

tmp=$(mktemp -d) || did_not_run "Could not create a temporary directory."
trap 'rm -rf "$tmp"' EXIT
resp="$tmp/resp"; hdrs="$tmp/hdrs"
# Key goes through a private config file, not the process list.
( umask 077; printf 'header = "X-RegulatorySignals-Key: %s"\n' "$RS_API_KEY" > "$tmp/cfg" )
body=$(jq -n --arg u "$RS_REPO_URL" '{repoUrl:$u, mode:"deterministic"}')

attempts="${RS_ATTEMPTS:-3}"; delay="${RS_RETRY_DELAY:-3}"; n=0; code="000"
while [ "$n" -lt "$attempts" ]; do
  n=$((n+1))
  code=$(curl -sS -o "$resp" -D "$hdrs" -w '%{http_code}' --connect-timeout 20 --max-time "${RS_MAX_TIME:-150}" --max-filesize 5000000 \
    -X POST "$RS_API_URL/api/v1/scan" -K "$tmp/cfg" -H "Content-Type: application/json" --data "$body" 2>"$tmp/err") || code="000"
  case "$code" in 429|5??|000) [ "$n" -lt "$attempts" ] && sleep "$delay" && continue ;; esac
  break
done

if [ "$code" != "200" ]; then
  msg=$(jq -r '(.error // empty) | tostring' "$resp" 2>/dev/null | head -n1)
  [ "$code" = "000" ] && msg="${msg:-$(head -n1 "$tmp/err" 2>/dev/null)}"
  did_not_run "HTTP $code after $n attempt(s). ${msg}"
fi
jq -e '.checks | type == "object"' "$resp" >/dev/null 2>&1 || did_not_run "The API answered HTTP 200 but the body is not a result with a checks object."

# Counts are only trusted when they are real numbers.
findings=$(jq '.checks as $c | [ (($c.resOkViolationCount | numbers) > 0), ($c.webhookSilentSuccess == true), (($c.buttonRouteGapCount | numbers) > 0),
                 ($c.paymentWebhookVerified == false), ($c.stripeWebhookVerified == false) ] | map(select(.)) | length' "$resp") || did_not_run "Could not read the result."
case "$findings" in ''|*[!0-9]*) did_not_run "Could not read the result." ;; esac
repo_clean=$(clean "$RS_REPO_URL" 200)
rows=$(jq -r '.checks | def v: if . == null then "n/a" elif type == "boolean" or type == "number" then tostring else (tostring | gsub("[\u0000-\u001f\u007f|`<>]"; " ") | .[0:80]) end;
  "| Rate limiting detected | \(.hasRateLimiting | v) |\n| Unchecked fetch() responses | \(.resOkViolationCount | v) |\n| Webhook silent success | \(.webhookSilentSuccess | v) |\n| Payment webhook verified | \(.paymentWebhookVerified | v) |\n| Stripe webhook verified | \(.stripeWebhookVerified | v) |\n| Button-to-route gaps | \(.buttonRouteGapCount | v) |\n| Row-level security enabled | \(.rlsTablesEnabled | v) |\n| AI providers | \(((.aiProviders // []) | if type == "array" then map(tostring | gsub("[\u0000-\u001f\u007f|`<>]"; " ") | .[0:40]) | join(", ") else "n/a" end) | if . == "" then "none" else . end) |"' "$resp") || did_not_run "Could not read the result."
{
  echo "### Regulatory Signals check"
  echo
  echo "Repository: \`$repo_clean\` (default branch, deterministic checks)"
  echo
  echo "| Check | Result |"
  echo "|---|---|"
  echo "$rows"
  echo
  echo "Checks reporting a problem: **$findings**. Powered by [Regulatory Signals](https://www.regulatorysignals.com)."
} >> "$SUMMARY"
echo "findings=$findings" >> "$OUT"
if [ "$fail_flag" = "true" ] && [ "$findings" -gt 0 ]; then
  echo "::error::Regulatory Signals: $findings check(s) reported a problem."
  exit 1
fi
exit 0
