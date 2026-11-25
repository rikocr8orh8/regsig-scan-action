# Regulatory Signals repo check (GitHub Action)

Runs the [Regulatory Signals](https://www.regulatorysignals.com) deterministic checks on a **public** GitHub repository and writes the result to the job summary. No model is called and no audit quota is used.

Checks reported: unchecked `fetch()` responses, webhook handlers that return success without verifying, payment/Stripe webhook signature verification, button-to-route gaps, rate limiting detected, row-level security, AI providers in use.

## Use

```yaml
name: regsig
on:
  push:
    branches: [main]
  schedule:
    - cron: "0 6 * * 1"
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: rikocr8orh8/regsig-scan-action@v1
        with:
          api-key: ${{ secrets.REGULATORY_SIGNALS_API_KEY }}
          fail-on-findings: "false"   # "true" fails the job when a check reports a problem
```

| Input | Default | Meaning |
|---|---|---|
| `api-key` | required | Your Regulatory Signals API key, stored as a repository secret |
| `repo-url` | the current repository | GitHub URL to check |
| `fail-on-findings` | `false` | Fail the job when a check reports a problem |
| `api-url` | `https://www.regulatorysignals.com` | API base URL |

Output: `findings`, the number of checks that reported a problem (`0` when the check did not run).

The action needs no repository token. A workflow that only runs it can set `permissions: {}`.

## What it does not do

- It checks the repository's **default branch**, not the pull request branch: the API takes a repository URL and has no ref parameter. Run it on `push` to the default branch or on a schedule, not as a pull-request gate.
- **Public repositories only.** The API reads the repository without your credentials.
- A missing (empty), invalid or rate-limited key, or an unreachable or failing API, prints a warning and does **not** fail your build. Rate limits (429) and server errors (5xx) are retried up to 3 attempts in total. Only a reported problem fails the job, and only with `fail-on-findings: "true"`. Because of this, a service outage looks like a pass: read the warning, or check that `findings` was set.
- On pull requests from forks GitHub does not pass secrets, so the key is empty and the check is skipped with a warning.
- `api-url` must start with `https://` (plain `http://` is accepted only for `localhost` and `127.0.0.1`, for testing). Otherwise the check is skipped and the key is not sent.

## API key

Create a key at [regulatorysignals.com/dashboard/settings](https://www.regulatorysignals.com/dashboard/settings). Today API keys need a Professional or Enterprise plan.

## Test

`bash test/test.sh` runs the script against a local fake API (needs bash, curl, jq, python3 with PyYAML). It makes no request to the real service.

MIT licensed.
