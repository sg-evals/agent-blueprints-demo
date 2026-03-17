#!/bin/bash
# Run the deterministic demo: push a CI-failure commit and watch the agent investigate.
#
# Usage:
#   ./demo/run_demo.sh                # GitHub Actions on ubuntu-latest (requires GitHub secrets)
#   ./demo/run_demo.sh --self-hosted  # Self-hosted runner (inherits local env vars)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONOREPO="${MONOREPO_DIR:-../agent-blueprints-demo-monorepo}"
BRANCH_SUFFIX="$(date +%s)"
TRIGGER_BRANCH="demo/trigger-${BRANCH_SUFFIX}"
SELF_HOSTED=false

# Parse args
for arg in "$@"; do
  case "$arg" in
    --self-hosted) SELF_HOSTED=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

echo "=== Agent Blueprints Demo ==="
if $SELF_HOSTED; then
  echo "Mode: self-hosted runner (local env vars, no GitHub secrets needed)"
fi
echo ""

# ─────────────────────────────────────────────────────────────
# Self-hosted mode: start the runner before pushing
# ─────────────────────────────────────────────────────────────
if $SELF_HOSTED; then
  echo "Starting self-hosted runner..."
  bash "$SCRIPT_DIR/setup_runner.sh" --background
  echo ""
  # Give the runner a moment to connect
  echo "Waiting for runner to connect to GitHub..."
  sleep 5
fi

# ─────────────────────────────────────────────────────────────
# Trigger CI by pushing failure branch
# ─────────────────────────────────────────────────────────────
echo "Step 1: Creating trigger branch from demo/ci-failure-001..."
cd "$MONOREPO"
git checkout demo/ci-failure-001 2>/dev/null
git checkout -b "$TRIGGER_BRANCH" 2>/dev/null

echo ""
echo "Step 2: Pushing to trigger CI..."
git push origin "$TRIGGER_BRANCH" 2>/dev/null

echo ""
echo "Step 3: CI will run and fail on TestRetryBackoffZero"
echo "Step 4: GitHub webhook fires investigate workflow"
if $SELF_HOSTED; then
  echo "Step 5: Self-hosted runner picks up the job (using local ANTHROPIC_API_KEY + SOURCEGRAPH_ACCESS_TOKEN)"
else
  echo "Step 5: ubuntu-latest runner picks up the job (using GitHub secrets)"
fi
echo "Step 6: Agent investigates via Sourcegraph Deep Search + MCP"
echo "Step 7: Agent posts root-cause analysis comment on commit"
echo ""
if $SELF_HOSTED; then
  echo "Expected timeline: 30-60 seconds"
else
  echo "Expected timeline: 20-40 seconds"
fi
echo ""
echo "Monitor at: https://github.com/sg-evals/agent-blueprints-demo-monorepo/actions"
echo ""

# ─────────────────────────────────────────────────────────────
# Poll for investigation comment
# ─────────────────────────────────────────────────────────────
COMMIT_SHA=$(git rev-parse HEAD)
echo "Watching commit ${COMMIT_SHA:0:8} for investigation comment..."

COMMENT_FOUND=false
for i in $(seq 1 90); do
  COMMENTS=$(gh api "repos/sg-evals/agent-blueprints-demo-monorepo/commits/$COMMIT_SHA/comments" --jq 'length' 2>/dev/null || echo "0")
  if [ "$COMMENTS" -gt 0 ]; then
    echo ""
    echo "Investigation comment posted!"
    echo ""
    gh api "repos/sg-evals/agent-blueprints-demo-monorepo/commits/$COMMIT_SHA/comments" --jq '.[0].body' 2>/dev/null
    COMMENT_FOUND=true
    break
  fi
  printf "."
  sleep 2
done

if ! $COMMENT_FOUND; then
  echo ""
  echo "Timed out waiting for investigation comment."
  echo "Check workflow status at: https://github.com/sg-evals/agent-blueprints-demo-monorepo/actions"
fi

echo ""

# ─────────────────────────────────────────────────────────────
# Self-hosted mode: tear down runner
# ─────────────────────────────────────────────────────────────
if $SELF_HOSTED; then
  echo "Tearing down self-hosted runner..."
  bash "$SCRIPT_DIR/teardown_runner.sh"
  echo ""
fi

echo "Demo complete."
