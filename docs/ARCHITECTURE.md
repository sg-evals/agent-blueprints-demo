# Architecture Reference

## System Overview

```
CI fails (GitHub Actions)
    │
    ▼
investigate.yml triggers (workflow_run on CI Fast failure)
    │
    ▼
Claude Code agent launches on self-hosted runner
    │  with .mcp.json → Sourcegraph MCP server
    │
    ├── sg_keyword_search  → find the failing test
    ├── sg_read_file       → read test + implementation
    ├── sg_go_to_definition → trace the code under test
    ├── sg_commit_search   → find what changed
    │
    ▼
investigation_output.md → GitHub commit comment
```

No custom infrastructure. No Cloudflare. The agent is Claude Code with Sourcegraph MCP configured via `.mcp.json`.

## File Layout

```
agent-blueprints-demo/
├── .claude/
│   └── settings.json          # Pre-approved tool permissions (non-interactive)
├── .mcp.json                  # Sourcegraph MCP server config
├── CLAUDE.md                  # Agent investigation instructions
├── investigate.sh             # Launches Claude Code with MCP
├── blueprints/
│   └── ci_failure_investigator/
│       ├── blueprint.yaml     # Declarative workflow definition
│       └── scenarios/         # Deterministic test scenarios
├── demo/
│   ├── setup.sh           # One-command zero-to-ready setup
│   ├── run_demo.sh        # Live demo (pushes to GitHub)
│   ├── preflight.sh       # Prerequisite checker
│   ├── reset_demo.sh      # Reset demo state (clean up branches)
│   ├── setup_runner.sh    # Register self-hosted runner
│   ├── teardown_runner.sh # Deregister runner
│   ├── local_demo.sh      # Offline demo (no credentials)
│   └── .env.example       # Token format reference
└── docs/
    └── ARCHITECTURE.md    # This file
```

## Directory Layout on Disk

```
~/your-workspace/
├── agent-blueprints-demo/           # This repo — agent runtime
└── agent-blueprints-demo-monorepo/  # Target Go monorepo
```

Both repos must be siblings in the same parent directory. `setup.sh` enforces this.

## MCP Configuration (`.mcp.json`)

```json
{
  "mcpServers": {
    "sourcegraph": {
      "type": "http",
      "url": "https://sourcegraph.sourcegraph.com/.api/mcp/v1",
      "headers": { "Authorization": "token ${SOURCEGRAPH_ACCESS_TOKEN}" }
    }
  }
}
```

This gives Claude Code access to all Sourcegraph MCP tools:
- `mcp__sourcegraph__sg_keyword_search` — exact symbol search
- `mcp__sourcegraph__sg_nls_search` — semantic search
- `mcp__sourcegraph__sg_read_file` — read indexed files
- `mcp__sourcegraph__sg_go_to_definition` — symbol navigation
- `mcp__sourcegraph__sg_find_references` — cross-repo references
- `mcp__sourcegraph__sg_commit_search` — git history
- `mcp__sourcegraph__sg_deepsearch` — deep semantic investigation

## Permission Pre-approval (`.claude/settings.json`)

The investigation workflow runs non-interactively inside GitHub Actions. Without
`.claude/settings.json`, Claude Code prompts for tool permission on first use —
which hangs a non-interactive shell forever.

`settings.json` pre-approves the exact tools investigate.sh passes via `--allowedTools`,
so no interactive prompt appears.

## Automated CI Trigger

The monorepo has `.github/workflows/investigate.yml` that fires when CI fails:

```
workflow_run (CI Fast, completed, failure)
  → checkout agent-blueprints-demo
  → extract failing test from CI logs
  → run investigate.sh with Claude Code + MCP
  → post investigation as GitHub commit comment
```

### `workflow_run` trigger gotcha

`workflow_run` **only fires from the workflow file on the default branch** (`main`).
If `investigate.yml` hasn't been pushed to `main` in the monorepo, the trigger
silently won't work — even if CI Fast fails on every branch.

`preflight.sh` checks for this condition automatically.

## Self-hosted Runner

The investigation workflow runs on your laptop (`[self-hosted, demo-runner]`), not
on GitHub-hosted runners. This means:

- Your API keys never leave your machine
- No GitHub Secrets configuration needed
- The runner inherits your shell environment (including `ANTHROPIC_API_KEY` and `SOURCEGRAPH_ACCESS_TOKEN`)

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

## Demo Scenario: ci-failure-001

| Field | Value |
|---|---|
| **Failing test** | `TestRetryBackoffZero` |
| **Root cause** | `libs/retry/backoff.go` — removed attempt clamp |
| **Error** | `invalid negative backoff delay: -100ms` |
| **Branches** | `demo/baseline` (passes) / `demo/ci-failure-001` (fails) |

## Companion Monorepo

[`sg-evals/agent-blueprints-demo-monorepo`](https://github.com/sg-evals/agent-blueprints-demo-monorepo) — 8 Go microservices, 6 shared libraries, CI workflow.
