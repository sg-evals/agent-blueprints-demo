# Agent Blueprints Demo

Deterministic demo of background coding agents powered by **Sourcegraph Deep Search** and **MCP**.

An agent automatically investigates CI test failures, identifies root causes via code search, and posts analysis as GitHub comments.

## Architecture

```
GitHub CI failure
    │
    ▼
Cloudflare Worker (webhook-ingress)
    │  validates signature, filters failures
    ▼
Cloudflare Queue
    │
    ▼
Cloudflare Worker (queue-consumer)
    │  fetches CI logs
    │  queries Sourcegraph Deep Search
    │  expands symbols via MCP
    │  generates investigation summary
    ▼
GitHub commit comment
```

## Quick Start — Local Demo

```bash
# 1. Install dependencies
cd agent-blueprints-demo
npm install

# 2. Run preflight checks
bash demo/preflight.sh

# 3. Run the full local demo (no external services needed)
bash demo/local_demo.sh
```

## Project Structure

```
agent-blueprints-demo/
├── workers/
│   ├── webhook-ingress/     # Receives GitHub webhooks
│   └── queue-consumer/      # Processes investigation jobs
├── durable_objects/
│   └── investigation_run.ts # Per-investigation state
├── runtime/
│   ├── github/              # GitHub API client
│   ├── sourcegraph/         # Deep Search + MCP client
│   ├── llm/                 # Claude API (demo mode fallback)
│   ├── blueprint/           # Blueprint loader + executor
│   ├── output/              # Comment formatter
│   └── state/               # Investigation state management
├── blueprints/
│   └── ci_failure_investigator/
│       ├── blueprint.yaml   # Declarative workflow
│       └── scenarios/       # Deterministic test scenarios
├── demo/
│   ├── local_demo.sh        # Full local demo (no external services)
│   ├── run_demo.sh          # Live demo (pushes to GitHub)
│   ├── reset_demo.sh        # Reset demo state
│   ├── simulate_webhook.sh  # Local webhook testing
│   ├── verify_sourcegraph.sh # Sourcegraph API verification
│   └── preflight.sh         # Prerequisite checker
├── wrangler.toml             # Cloudflare Workers config
├── package.json
└── tsconfig.json
```

## Demo Scenario: ci-failure-001

| Field | Value |
|---|---|
| **Failing test** | `TestRetryBackoffZero` |
| **Package** | `apps/worker-reconcile` |
| **Root cause** | `libs/retry/backoff.go` — removed attempt clamp, linear formula yields negative delay |
| **Error** | `invalid negative backoff delay: -100ms` |
| **Confidence** | Medium |

### Branches

| Branch | Status |
|---|---|
| `demo/baseline` | All tests pass |
| `demo/ci-failure-001` | `TestRetryBackoffZero` fails |

## Live Demo (GitHub + Cloudflare)

### Prerequisites

```bash
export GITHUB_TOKEN="ghp_..."
export SOURCEGRAPH_ACCESS_TOKEN="sgp_..."
export ANTHROPIC_API_KEY="sk-ant-..."
```

### Setup

```bash
# Deploy webhook worker
npx wrangler deploy

# Configure GitHub webhook on the monorepo:
#   URL: https://agent-blueprints-demo.<account>.workers.dev/webhook/github
#   Events: Workflow runs
#   Secret: <your webhook secret>

# Set worker secrets
npx wrangler secret put GITHUB_TOKEN
npx wrangler secret put GITHUB_WEBHOOK_SECRET
npx wrangler secret put SOURCEGRAPH_ACCESS_TOKEN
npx wrangler secret put ANTHROPIC_API_KEY
```

### Run

```bash
bash demo/run_demo.sh
```

### Reset

```bash
bash demo/reset_demo.sh
```

## Companion Monorepo

The synthetic monorepo lives at `sg-evals/agent-blueprints-demo-monorepo`:

- 8 Go microservices with realistic cross-service dependencies
- 6 shared libraries (authz, eventbus, retry, httpclient, featureflags, observability)
- CI workflow (`.github/workflows/ci-fast.yml`)
- Deterministic repo generator (`tools/gen_repo`)

## Tests

```bash
# Run all 47 tests
npx vitest run

# TypeScript type check
npx tsc --noEmit
```

## Sourcegraph Integration

The agent uses two Sourcegraph capabilities:

1. **Deep Search** (`sg_deepsearch`) — semantic, broad investigation
2. **MCP tools** — precise, symbol-level:
   - `sg_go_to_definition` — navigate to function definition
   - `sg_find_references` — find all callers
   - `sg_read_file` — read source files
   - `sg_keyword_search` — exact string/regex match
   - `sg_nls_search` — natural language search

```bash
# Verify Sourcegraph integration
export SOURCEGRAPH_ACCESS_TOKEN="sgp_..."
bash demo/verify_sourcegraph.sh
```
