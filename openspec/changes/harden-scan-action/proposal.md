## Why
The action's README says a missing key never fails the build, but the script exits non-zero when the key is empty (for example on fork pull requests, where secrets are not passed). API error text and API fields are written into workflow commands and Markdown without sanitising, and the key is passed on the curl command line.

## What Changes
- scan.sh: warn and exit 0 on an empty key; validate the API URL (https, or loopback for tests); retry 429/5xx a bounded number of times; sanitise API text before it reaches workflow commands or the job summary; validate the JSON before using it; keep the key out of the process list; clean up temp files.
- action.yml: pass `github.action_path` through env, not inline in the shell script.
- Tests: fake local API server cases (429, 5xx, bad JSON, hostile text, slow response) and an input matrix; static checks on action.yml and the workflow.
- README: align claims with behaviour.

## Impact
Code and tests only. No new dependencies, no recurring cost, no change to the API contract.
