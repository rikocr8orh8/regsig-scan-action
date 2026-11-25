#!/usr/bin/env bash
# Runs scan.sh against a local fake API and checks action.yml statically. Needs bash, curl, jq, python3 (with PyYAML for the action.yml checks).
set -u
cd "$(dirname "$0")/.."
fail=0; port=18765; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export RS_RETRY_DELAY=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$3' got '$2'"; fail=1; fi; }
wait_port() { for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/$1) 2>/dev/null && return 0; sleep 0.1; done; return 1; }
# run CASE FAILFLAG [VAR=value ...] -> sets RC, FINDINGS; files $T/log $T/sum $T/out $T/req
run() {
  local c=$1 f=$2; shift 2; : > "$T/req"; : > "$T/out"; : > "$T/sum"
  python3 test/mock_server.py $port "$T/req" "$c" & local pid=$!
  wait_port $port || { echo "FAIL mock server did not start"; fail=1; }
  env RS_API_KEY=k_test RS_REPO_URL=https://github.com/o/r RS_API_URL=http://127.0.0.1:$port RS_FAIL="$f" "$@" \
    GITHUB_OUTPUT="$T/out" GITHUB_STEP_SUMMARY="$T/sum" bash scan.sh >"$T/log" 2>&1
  RC=$?; kill $pid 2>/dev/null; wait $pid 2>/dev/null; FINDINGS=$(sed -n 's/^findings=//p' "$T/out"); port=$((port+1))
}
reqs() { grep -c . "$T/req"; }
first() { head -n1 "$T/req" | jq -r "$1"; }
# Workflow-command lines in the log must only be the ones the script itself prints.
cmd_lines() { grep -c '^::' "$T/log"; }

run clean true;  check "clean passes even with fail-on-findings" "$RC/$FINDINGS" "0/0"
check "request path" "$(first .path)" "/api/v1/scan"
check "request key header" "$(first .key)" "k_test"
check "request content type" "$(first .ctype)" "application/json"
check "request mode deterministic" "$(first .body.mode)" "deterministic"
check "request repoUrl" "$(first .body.repoUrl)" "https://github.com/o/r"
check "clean: exactly one request" "$(reqs)" "1"
run bad false;   check "findings reported but build passes by default" "$RC/$FINDINGS" "0/3"
check "summary has the table" "$(grep -c 'Unchecked fetch() responses | 3' "$T/sum")" "1"
run bad true;    check "fail-on-findings fails the job" "$RC/$FINDINGS" "1/3"
run bad TRUE;    check "fail-on-findings is case-insensitive" "$RC/$FINDINGS" "1/3"
run bad yes;     check "fail-on-findings with an unknown value does not fail" "$RC/$FINDINGS" "0/3"
check "unknown fail-on-findings value warns" "$(grep -c "::warning::fail-on-findings must be" "$T/log")" "1"
run bad "";      check "fail-on-findings empty means false" "$RC/$FINDINGS" "0/3"
run unauth true; check "401 never breaks the build" "$RC/$FINDINGS" "0/0"
check "401 prints a warning" "$(grep -c '::warning::' "$T/log")" "1"
check "401 is not retried" "$(reqs)" "1"
check "401 summary names the cause" "$(grep -c 'Invalid or revoked API key' "$T/sum")" "1"
run r429 true;   check "429 never breaks the build" "$RC/$FINDINGS" "0/0"
check "429 is retried up to 3 attempts" "$(reqs)" "3"
run r500 true;   check "500 never breaks the build" "$RC/$FINDINGS" "0/0"
check "500 non-json body still warns once" "$(grep -c '::warning::' "$T/log")" "1"
run flaky true;  check "5xx then 200 recovers and reports" "$RC/$FINDINGS" "1/3"
check "flaky made 2 requests" "$(reqs)" "2"
run clean true RS_ATTEMPTS=1; check "RS_ATTEMPTS=1 means no retry" "$(reqs)" "1"
run r429 true RS_ATTEMPTS=1;  check "429 with one attempt makes one request" "$(reqs)" "1"
run badjson true; check "200 with a non-JSON body does not fail or print jq errors" "$RC/$FINDINGS/$(grep -c 'jq:' "$T/log")" "0/0/0"
check "non-JSON body warns once" "$(grep -c '::warning::' "$T/log")" "1"
run empty true;  check "200 with no checks object is 'did not run', not a clean result" "$RC/$FINDINGS/$(grep -c 'not a result' "$T/sum")" "0/0/1"
run checks_array true; check "checks that is not an object is 'did not run'" "$RC/$FINDINGS" "0/0"
run string_counts true; check "string counts are not trusted as numbers" "$RC/$FINDINGS" "0/0"
run providers_string true; check "aiProviders that is not an array does not crash" "$RC/$FINDINGS/$(grep -c 'AI providers | n/a' "$T/sum")" "0/0/1"
run evil_error true; check "hostile error text: build passes" "$RC/$FINDINGS" "0/0"
check "hostile error text injects no workflow command" "$(cmd_lines)" "1"
check "hostile error text injects no command in the summary" "$(grep -c '^::' "$T/sum")" "0"
run evil_fields false; check "hostile 200 fields: build passes" "$RC/$FINDINGS" "0/0"
check "hostile fields inject no workflow command in log" "$(cmd_lines)" "0"
check "hostile fields inject no command or heading in summary" "$(grep -cE '^(::|# )' "$T/sum")" "0"
check "hostile fields leave no raw HTML in summary" "$(grep -c '<' "$T/sum")" "0"
check "summary table keeps one row per check" "$(grep -c '^| ' "$T/sum")" "9"
run slow true RS_MAX_TIME=1 RS_ATTEMPTS=1; check "slow API times out and never breaks the build" "$RC/$FINDINGS" "0/0"
check "timeout names the cause" "$(grep -c 'HTTP 000' "$T/sum")" "1"
run clean true "RS_REPO_URL=https://github.com/o/r\`
# x\$(id)<b>"; check "hostile repo url: build passes" "$RC/$FINDINGS" "0/0"
check "hostile repo url is sent verbatim as JSON data" "$(first .body.repoUrl | head -c 24)" "https://github.com/o/r\`"
check "hostile repo url is not interpreted (no backtick or tag in summary line)" "$(grep '^Repository:' "$T/sum" | grep -c '<')" "0"
check "hostile repo url cannot start a Markdown heading line" "$(grep -c '^# x' "$T/sum")" "0"
check "hostile repo url keeps the summary to one Repository line" "$(grep -c '^Repository:' "$T/sum")" "1"
run bad true "RS_REPO_URL=https://github.com/o/r-😀-שלום-$(printf '\xe2\x80\xae')x"; check "emoji and RTL repo url is sent verbatim" "$(first .body.repoUrl)" "https://github.com/o/r-😀-שלום-$(printf '\xe2\x80\xae')x"
long=$(head -c 10000 /dev/zero | tr '\0' 'a'); run clean true "RS_REPO_URL=https://github.com/o/$long"; check "10000-char repo url is sent in full" "$(first '.body.repoUrl|length')" "$((21 + 10000))"
check "10000-char repo url is cut in the summary" "$(grep '^Repository:' "$T/sum" | wc -c | awk '{print ($1 < 400)}')" "1"
run boundary true; check "count -1 is not a finding, count 1 is" "$RC/$FINDINGS" "1/1"
run boundary0 true; check "counts at 0 are not findings" "$RC/$FINDINGS" "0/0"
run clean false; cp "$T/sum" "$T/sum1"; run clean false; check "same input gives the same summary (deterministic, no timestamps)" "$(cmp -s "$T/sum" "$T/sum1" && echo same)" "same"
run clean true RS_API_KEY=; check "empty key warns and does not fail" "$RC/$FINDINGS/$(grep -c '::warning::' "$T/log")" "0/0/1"
check "empty key makes no request" "$(reqs)" "0"
check "empty key message mentions forks" "$(grep -c 'forks' "$T/sum")" "1"
run clean true RS_REPO_URL=; check "empty repo url warns, no request" "$RC/$(reqs)" "0/0"
# Dead local proxy: proves the default https URL is used without any traffic leaving the machine.
run clean true RS_API_URL= HTTPS_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 NO_PROXY= no_proxy= RS_ATTEMPTS=1
check "empty api-url falls back to the https default (tried, failed locally, build passes)" "$RC/$(reqs)/$(grep -c 'HTTP 000' "$T/sum")" "0/0/1"
run clean true "RS_API_KEY=k 'with space'\$(id)"; check "odd key is sent verbatim, not shell-interpreted" "$(first .key)" "k 'with space'\$(id)"
run clean true 'RS_API_KEY=k"q\b'; check "key with quote and backslash is sent verbatim" "$(first .key)" 'k"q\b'
run clean true "RS_API_KEY=$(printf 'k"\noutput = "%s/pwned"' "$T")"; check "key with a newline is refused, no request, no file written" "$RC/$(reqs)/$(ls "$T/pwned" 2>/dev/null | wc -l)" "0/0/0"
run clean true RS_ATTEMPTS=abc; check "non-numeric RS_ATTEMPTS falls back to 3 and still works" "$RC/$FINDINGS" "0/0"
run huge true; check "a response over the size cap is 'did not run', not a result" "$RC/$FINDINGS/$(grep -c 'Did not run' "$T/sum")" "0/0/1"
run slow true RS_MAX_TIME=1 RS_ATTEMPTS=3; check "a timeout is not retried" "$(reqs)" "1"
run clean true RS_API_URL=http://example.com; check "plain http to a remote host is refused" "$RC/$(reqs)/$(grep -c 'must start with https' "$T/sum")" "0/0/1"
run clean true RS_API_URL=http://127.0.0.1.evil.example; check "loopback-lookalike host is refused (by the URL check, not by a failed connection)" "$RC/$(reqs)/$(grep -c 'must start with https' "$T/sum")" "0/0/1"
run clean true RS_API_URL=http://localhost; check "localhost http is allowed (then fails to connect, build passes)" "$RC" "0"
RS_API_KEY=k RS_REPO_URL=x RS_API_URL=http://127.0.0.1:9 RS_FAIL=true RS_ATTEMPTS=1 GITHUB_OUTPUT="$T/out" GITHUB_STEP_SUMMARY="$T/sum" bash scan.sh >"$T/log" 2>&1
check "unreachable API never breaks the build" "$?" "0"
# key never appears on any process command line while curl runs
python3 test/mock_server.py $port "$T/req" slow & pid=$!; wait_port $port
RS_API_KEY=k_SECRET_PROBE RS_REPO_URL=x RS_API_URL=http://127.0.0.1:$port RS_MAX_TIME=3 RS_ATTEMPTS=1 GITHUB_OUTPUT="$T/out" GITHUB_STEP_SUMMARY="$T/sum" bash scan.sh >"$T/log" 2>&1 &
spid=$!; sleep 1.2
check "key is not on any command line while curl runs" "$(ps -eo args | grep -v grep | grep -c k_SECRET_PROBE)" "0"
wait $spid; kill $pid 2>/dev/null; wait $pid 2>/dev/null; port=$((port+1))
before=$(ls -d "${TMPDIR:-/tmp}"/tmp.* 2>/dev/null | wc -l); run clean false; run bad false; after=$(ls -d "${TMPDIR:-/tmp}"/tmp.* 2>/dev/null | wc -l)
check "scan.sh leaves no temp files behind" "$after" "$before"

# ---- static checks on action.yml and the workflow ----
python3 - <<'PY' > "$T/static" 2>&1
import re, sys, yaml
a = yaml.safe_load(open("action.yml"))
step = a["runs"]["steps"][0]
res = []
res.append(("composite action", a["runs"]["using"] == "composite"))
res.append(("no ${{ }} inside run:", "${{" not in step["run"]))
env_exprs = " ".join(str(v) for v in step["env"].values())
res.append(("every declared input is consumed by the step env", all(("inputs." + k) in env_exprs for k in a["inputs"])))
used = set(re.findall(r"inputs\.([a-z-]+)", env_exprs))
res.append(("env only references declared inputs", used <= set(a["inputs"])))
res.append(("api-key is required", a["inputs"]["api-key"].get("required") is True))
res.append(("only api-key is required", [k for k, v in a["inputs"].items() if v.get("required")] == ["api-key"]))
res.append(("output findings maps to the scan step", "steps.scan.outputs.findings" in a["outputs"]["findings"]["value"]))
res.append(("step id matches output reference", step.get("id") == "scan"))
res.append(("step shell is bash", step.get("shell") == "bash"))
res.append(("fail-on-findings default is false", str(a["inputs"]["fail-on-findings"]["default"]) == "false"))
res.append(("api-url default is https", a["inputs"]["api-url"]["default"].startswith("https://")))
wf = open(".github/workflows/test.yml").read()
res.append(("workflow has a permissions block", re.search(r"^permissions:", wf, re.M) is not None))
res.append(("workflow does not use pull_request_target", "pull_request_target" not in wf))
res.append(("every workflow action is pinned to a SHA", all(re.search(r"@[0-9a-f]{40}", l) for l in wf.splitlines() if re.search(r"uses:\s*\S+@", l))))
res.append(("no github.event text in a run step", "github.event." not in wf))
sh = open("scan.sh").read()
res.append(("scan.sh uses set -uo pipefail", "set -uo pipefail" in sh))
res.append(("scan.sh never passes the key on the command line", "$RS_API_KEY\"" not in sh.split("printf 'header")[1].split("\n",1)[1]))
for name, ok in res: print(("ok   " if ok else "FAIL ") + name)
PY
if [ ! -s "$T/static" ]; then echo "FAIL static checks produced no output (is PyYAML installed?)"; fail=1; fi
cat "$T/static"; grep -q '^FAIL' "$T/static" && fail=1
exit $fail
