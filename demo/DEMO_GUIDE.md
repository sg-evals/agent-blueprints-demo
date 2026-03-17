# Agent Blueprints Demo Guide

This guide walks you through running the CI failure investigation demo end-to-end
on your laptop using a self-hosted GitHub Actions runner — no GitHub secrets required.

## How It Works

1. You push a branch with a seeded Go test failure to `sg-evals/agent-blueprints-demo-monorepo`
2. GitHub Actions runs CI Fast on `ubuntu-latest` → the test fails
3. The `investigate` workflow triggers on the CI failure and runs on your **self-hosted runner**
4. Claude Code + Sourcegraph MCP investigates the failure using your local API keys
5. The agent posts a root-cause analysis comment on the commit in GitHub

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Go | 1.22+ | https://go.dev/dl |
| Node.js | 18+ | https://nodejs.org |
| claude CLI | latest | `npm install -g @anthropic-ai/claude-code` |
| gh CLI | any | https://cli.github.com |
| git | any | pre-installed on most systems |

### Environment variables

Copy `demo/.env.example` to `demo/.env` and fill in your values:

```bash
cp demo/.env.example demo/.env
# Edit demo/.env with your credentials
```

Or export in your shell (add to `~/.bashrc` or `~/.zshrc` for persistence):

```bash
export ANTHROPIC_API_KEY="sk-ant-..."          # Anthropic Console: console.anthropic.com
export SOURCEGRAPH_ACCESS_TOKEN="sgp_..."      # Sourcegraph: sourcegraph.com/user/settings/tokens
export GITHUB_TOKEN="ghp_..."                  # GitHub: Settings → Developer settings → Personal access tokens
                                               # Scopes needed: repo (full), workflow
```

> **Note:** `GITHUB_TOKEN` needs `workflow` scope to register a self-hosted runner and `repo`
> scope to post commit comments.

### Repo access

You need push access to `sg-evals/agent-blueprints-demo-monorepo`. `preflight.sh` checks
this automatically. Ask a team admin to add you as a collaborator if you get a 403 when pushing.

---

## 5-Minute Setup

### Step 1: Run setup

```bash
cd ~  # or wherever you keep projects
git clone https://github.com/sg-evals/agent-blueprints-demo.git
cd agent-blueprints-demo
bash demo/setup.sh
```

`setup.sh` will:
- Clone the companion monorepo if it's not already present (both repos must be siblings)
- Validate the directory layout
- Run preflight checks — fix any `FAIL` items before continuing
- Optionally register the runner (or let `run_demo.sh` do it automatically)

### Step 2: Run the demo

```bash
./demo/run_demo.sh
```

The runner starts automatically, the trigger branch is pushed, and the script polls
for the investigation comment. When it appears, the comment text is printed.

---

## Timing

Wall-clock time from running `run_demo.sh` to seeing the comment:

| Phase | Typical time |
|-------|-------------|
| Runner starts and connects | ~5s |
| CI Fast runs on ubuntu-latest | ~30s |
| `workflow_run` trigger delay (GitHub) | ~30–60s |
| Agent investigates (Claude + MCP) | ~60–120s |
| **Total** | **2–4 minutes** |

During the demo, `run_demo.sh` shows which phase is active. Open the Actions tab to watch live:

```
https://github.com/sg-evals/agent-blueprints-demo-monorepo/actions
```

---

## What You'll See

The commit comment looks like:

```
## Automated Investigation

**Failing test:** `TestRetryBackoffZero`

**Likely root cause:**
The `BackoffZero` function returns a non-zero initial delay ...

**Suggested fix:**
Change line 23 in libs/retry/backoff.go: return 0 instead of b.InitialDelay
```

---

## Running the Pieces Separately

If you want more control, you can run each piece individually:

### Start the runner manually

```bash
# Foreground (Ctrl-C to stop)
./demo/setup_runner.sh

# Background
./demo/setup_runner.sh --background
```

### Push the trigger branch manually

```bash
cd ../agent-blueprints-demo-monorepo
git checkout demo/ci-failure-001
git checkout -b demo/trigger-$(date +%s)
git push origin HEAD
```

### Tear down the runner

```bash
cd ../agent-blueprints-demo
./demo/teardown_runner.sh
```

### Clean up trigger branches

```bash
./demo/reset_demo.sh          # Bulk cleanup of demo/trigger-* branches
```

---

## Troubleshooting

### workflow_run trigger never fires

**This is the most common silent failure.** `workflow_run` **only fires from the
workflow file on the default branch** (`main`). If `investigate.yml` hasn't been
pushed to `main` in the monorepo, the trigger silently never fires — even when
CI Fast fails.

**Check:**
```bash
gh api "repos/sg-evals/agent-blueprints-demo-monorepo/contents/.github/workflows/investigate.yml" \
  --jq '.content' | base64 -d | grep "runs-on"
```

Should show `runs-on: [self-hosted, demo-runner]`. If not, push the updated workflow
to the main branch of the monorepo first.

`preflight.sh` checks this automatically.

### Runner won't connect

**Symptom:** `setup_runner.sh` completes but the workflow stays in "Queued" state.

**Check:**
```bash
cat ~/.github-runner-demo/runner.log | tail -20
```

**Common causes:**
- `GITHUB_TOKEN` expired or missing `workflow`/`repo` scopes → regenerate the token
- Runner already registered under a different name → `teardown_runner.sh` then re-run setup
- Firewall blocking outbound HTTPS to GitHub → check corporate proxy settings

### MCP auth fails

**Symptom:** Investigation workflow runs but posts a generic error comment or exits early.

**Check:**
```bash
# Verify tokens work locally
curl -s -H "Authorization: Bearer $SOURCEGRAPH_ACCESS_TOKEN" \
  "https://sourcegraph.com/.api/graphql" -d '{"query":"{currentUser{username}}"}' | python3 -m json.tool
```

**Common causes:**
- `SOURCEGRAPH_ACCESS_TOKEN` not exported before starting the runner → teardown, re-export, re-setup
- Token doesn't have `read` scope on Sourcegraph → create a new token with correct scopes
- `ANTHROPIC_API_KEY` expired or quota exhausted → check console.anthropic.com

### No push access to monorepo

**Symptom:** `git push` fails with `remote: Repository not found` or 403.

`preflight.sh` checks your collaborator permission level before you hit this at push time.
Ask a team admin to add you to `sg-evals/agent-blueprints-demo-monorepo` with write access.

### Runner registered but no jobs picked up

The runner labels must match what `investigate.yml` requests. The workflow requests
`[self-hosted, demo-runner]`. Setup installs those labels by default.

Verify:
```bash
gh api "repos/sg-evals/agent-blueprints-demo-monorepo/actions/runners" --jq '.runners[] | {name, labels: [.labels[].name], status}'
```

### Reset to a clean state

```bash
./demo/teardown_runner.sh     # Remove runner
./demo/reset_demo.sh          # Clean up trigger branches
```

---

## Architecture Reference

See [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) for system design, file layout, and
the full explanation of the `workflow_run` trigger gotcha.
