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

Export these in your shell (add to `~/.bashrc` or `~/.zshrc` for persistence):

```bash
export ANTHROPIC_API_KEY="sk-ant-..."          # Anthropic Console: console.anthropic.com
export SOURCEGRAPH_ACCESS_TOKEN="sgp_..."      # Sourcegraph: sourcegraph.com/user/settings/tokens
export GITHUB_TOKEN="ghp_..."                  # GitHub: Settings → Developer settings → Personal access tokens
                                               # Scopes needed: repo (full), workflow
```

> **Note:** `GITHUB_TOKEN` needs `workflow` scope to register a self-hosted runner and `repo`
> scope to post commit comments.

### Repo access

You need push access to `sg-evals/agent-blueprints-demo-monorepo`. Ask a team admin to add you
as a collaborator if you get a 403 when pushing.

---

## 5-Minute Setup

### Step 1: Clone both repos

```bash
cd ~  # or wherever you keep projects

git clone https://github.com/sg-evals/agent-blueprints-demo.git
git clone https://github.com/sg-evals/agent-blueprints-demo-monorepo.git
```

### Step 2: Run the preflight check

```bash
cd agent-blueprints-demo
./demo/preflight.sh
```

All checks should pass. Fix any `FAIL` items before continuing. `WARN` items are
optional for the self-hosted flow.

### Step 3: Run the demo

```bash
./demo/run_demo.sh --self-hosted
```

This script:
1. Starts a self-hosted runner on your laptop (background process)
2. Pushes the `demo/ci-failure-001` branch as `demo/trigger-<timestamp>`
3. Waits for the investigation comment to appear on the commit
4. Tears down the runner when done

### Step 4: Watch it run

Open the Actions tab while the demo runs:
- **CI Fast** runs on `ubuntu-latest` — will fail in ~30 seconds
- **Investigate CI Failure** runs on your self-hosted runner — posts a comment in ~60-90 seconds

The commit comment will look like:

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

---

## Troubleshooting

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

### investigate workflow not triggering

**Symptom:** CI Fast fails but `Investigate CI Failure` workflow never appears.

**Causes:**
- Workflow file uses `ubuntu-latest` runner (not updated yet) → check `.github/workflows/investigate.yml` has `runs-on: [self-hosted, demo-runner]`
- Runner is offline when CI Fast completes — GitHub won't re-queue the triggered workflow → push another trigger branch

### "Remote: Repository not found" when pushing

You need push access to `sg-evals/agent-blueprints-demo-monorepo`. Ask a team admin.

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

```
Your laptop
├── ~/.github-runner-demo/       # Runner binary + config (setup_runner.sh)
├── agent-blueprints-demo/       # Agent runtime (investigate.sh, CLAUDE.md, MCP config)
└── agent-blueprints-demo-monorepo/  # Target Go monorepo

GitHub
├── sg-evals/agent-blueprints-demo-monorepo
│   └── .github/workflows/
│       ├── ci-fast.yml          # Runs on ubuntu-latest, fails the test
│       └── investigate.yml      # Runs on self-hosted (your laptop)
└── Runner connection
    └── Your laptop ←→ api.github.com (outbound HTTPS only)
```

API keys never leave your machine. The runner inherits them from your shell environment.
