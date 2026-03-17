# Agent Blueprints Demo

Background coding agent that investigates CI failures using **Claude Code** + **Sourcegraph MCP**.

When a test fails in CI, the agent automatically:
1. Uses Sourcegraph MCP tools to search the codebase
2. Traces the failing test to its root cause
3. Posts an investigation report as a GitHub comment

---

## Quick Start (Self-Hosted Runner)

> **This is the recommended path.** Your API keys stay on your machine — no GitHub Secrets required.

**1. Run setup:**

```bash
cd ~/your-workspace
git clone https://github.com/sg-evals/agent-blueprints-demo.git
cd agent-blueprints-demo
bash demo/setup.sh
```

`setup.sh` will:
- Clone the companion monorepo (if not present)
- Check all prerequisites
- Verify your tokens work
- Optionally register the self-hosted runner

**2. Run the demo:**

```bash
./demo/run_demo.sh
```

That's it. The demo triggers CI, waits for the agent to investigate, and prints the
root-cause comment. Expected time: **2–5 minutes** (CI ~30s + trigger delay ~60s + investigation ~90s).

Monitor live at: https://github.com/sg-evals/agent-blueprints-demo-monorepo/actions

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Go | 1.22+ | https://go.dev/dl |
| Node.js | 18+ | https://nodejs.org |
| claude CLI | latest | `npm install -g @anthropic-ai/claude-code` |
| gh CLI | any | https://cli.github.com |

**Tokens required** (see `demo/.env.example`):

```bash
export ANTHROPIC_API_KEY="sk-ant-..."          # console.anthropic.com
export SOURCEGRAPH_ACCESS_TOKEN="sgp_..."      # sourcegraph.com → User Settings → Access tokens
export GITHUB_TOKEN="ghp_..."                  # Settings → Developer settings → Personal access tokens
                                               # Scopes: repo (full), workflow
```

You also need **push access** to `sg-evals/agent-blueprints-demo-monorepo`. Ask a team admin if you get a 403.

---

## Full Demo Guide

See **[DEMO_GUIDE.md](demo/DEMO_GUIDE.md)** for:
- Step-by-step walkthrough
- Troubleshooting common issues
- Running individual pieces separately

See **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** for system design and the `workflow_run` trigger gotcha.

---

## How It Works

```
CI fails (GitHub Actions)
    │
    ▼
investigate.yml triggers on your self-hosted runner
    │
    ▼
Claude Code agent + Sourcegraph MCP investigates
    │
    ▼
Root-cause analysis posted as GitHub commit comment
```

The runner is your laptop. API keys never leave your machine.

## Companion Monorepo

[`sg-evals/agent-blueprints-demo-monorepo`](https://github.com/sg-evals/agent-blueprints-demo-monorepo) — 8 Go microservices, 6 shared libraries, CI workflow.
