# Agent Blueprints Demo

Background coding agent that investigates CI failures using **Claude Code** + **Sourcegraph MCP**.

When a test fails in CI, the agent automatically:
1. Uses Sourcegraph MCP tools to search the codebase
2. Traces the failing test to its root cause
3. Posts an investigation report as a GitHub comment

## Architecture

```
CI fails (GitHub Actions)
    │
    ▼
investigate.yml triggers
    │
    ▼
Claude Code agent launches
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

## Quick Start

```bash
# Run the demo (with or without credentials)
bash demo/local_demo.sh

# Run a live investigation
export SOURCEGRAPH_ACCESS_TOKEN="sgp_..."
export ANTHROPIC_API_KEY="sk-ant-..."

./investigate.sh \
  --repo sg-evals/agent-blueprints-demo-monorepo \
  --test TestRetryBackoffZero \
  --error "invalid negative backoff delay: -100ms"
```

## Files

```
agent-blueprints-demo/
├── .mcp.json              # Sourcegraph MCP server config
├── CLAUDE.md              # Agent investigation instructions
├── investigate.sh         # Launches Claude Code with MCP
├── blueprints/
│   └── ci_failure_investigator/
│       ├── blueprint.yaml     # Declarative workflow definition
│       └── scenarios/         # Deterministic test scenarios
└── demo/
    ├── local_demo.sh      # Full local demo
    ├── preflight.sh       # Prerequisite checker
    ├── run_demo.sh        # Live demo (pushes to GitHub)
    └── reset_demo.sh      # Reset demo state
```

## How It Works

### MCP Configuration (`.mcp.json`)

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

### Automated CI Trigger

The monorepo has `.github/workflows/investigate.yml` that fires when CI fails:

```
workflow_run (CI Fast, completed, failure)
  → checkout agent-blueprints-demo
  → extract failing test from CI logs
  → run investigate.sh with Claude Code + MCP
  → post investigation as GitHub commit comment
```

### Demo Scenario: ci-failure-001

| Field | Value |
|---|---|
| **Failing test** | `TestRetryBackoffZero` |
| **Root cause** | `libs/retry/backoff.go` — removed attempt clamp |
| **Error** | `invalid negative backoff delay: -100ms` |
| **Branches** | `demo/baseline` (passes) / `demo/ci-failure-001` (fails) |

## Companion Monorepo

[`sg-evals/agent-blueprints-demo-monorepo`](https://github.com/sg-evals/agent-blueprints-demo-monorepo) — 8 Go microservices, 6 shared libraries, CI workflow.
