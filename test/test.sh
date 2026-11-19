#!/usr/bin/env bash
# Runs scan.sh against a local mock API. Needs bash, curl, jq, python3.
set -u
cd "$(dirname "$0")/.."
fail=0; port=18765; T=$(mktemp -d)
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$3' got '$2'"; fail=1; fi; }
run() { # case failflag -> sets RC, FINDINGS, SUMMARY_TEXT
  python3 test/mock_server.py $port "$T/req.json" "$1" & local pid=$!; sleep 0.6
  : > "$T/out"; : > "$T/sum"
  RS_API_KEY=k_test RS_REPO_URL=https://github.com/o/r RS_API_URL=http://127.0.0.1:$port RS_FAIL=$2 GITHUB_OUTPUT="$T/out" GITHUB_STEP_SUMMARY="$T/sum" bash scan.sh >"$T/log" 2>&1
  RC=$?; kill $pid 2>/dev/null; wait $pid 2>/dev/null; FINDINGS=$(sed -n 's/^findings=//p' "$T/out"); port=$((port+1))
}
run clean true;  check "clean passes even with fail-on-findings" "$RC/$FINDINGS" "0/0"
check "request path" "$(jq -r .path "$T/req.json")" "/api/v1/scan"
check "request key header" "$(jq -r .key "$T/req.json")" "k_test"
check "request mode deterministic" "$(jq -r .body.mode "$T/req.json")" "deterministic"
check "request repoUrl" "$(jq -r .body.repoUrl "$T/req.json")" "https://github.com/o/r"
run bad false;   check "findings reported but build passes by default" "$RC/$FINDINGS" "0/3"
check "summary has the table" "$(grep -c 'Unchecked fetch() responses | 3' "$T/sum")" "1"
run bad true;    check "fail-on-findings fails the job" "$RC/$FINDINGS" "1/3"
run unauth true; check "401 never breaks the build" "$RC/$FINDINGS" "0/0"
check "401 prints a warning" "$(grep -c '::warning::' "$T/log")" "1"
RS_API_KEY=k RS_REPO_URL=x RS_API_URL=http://127.0.0.1:9 RS_FAIL=true GITHUB_OUTPUT="$T/out" GITHUB_STEP_SUMMARY="$T/sum" bash scan.sh >"$T/log" 2>&1
check "unreachable API never breaks the build" "$?" "0"
exit $fail
