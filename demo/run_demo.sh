#!/bin/bash
# Run the deterministic demo: push a CI-failure commit and watch the agent investigate.
#
# Usage:
#   ./demo/run_demo.sh                  # Self-hosted runner (default, inherits local env vars)
#   ./demo/run_demo.sh --github-hosted  # GitHub Actions on ubuntu-latest (requires GitHub secrets)
#   ./demo/run_demo.sh --no-cleanup     # Skip automatic trigger branch cleanup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONOREPO="${MONOREPO_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)/agent-blueprints-demo-monorepo}"
BRANCH_SUFFIX="$(date +%s)"
TRIGGER_BRANCH="demo/trigger-${BRANCH_SUFFIX}"
SELF_HOSTED=true   # Default: self-hosted runner
AUTO_CLEANUP=true

# Source .env if present
ENV_FILE="$SCRIPT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

# Parse args
for arg in "$@"; do
  case "$arg" in
    --github-hosted) SELF_HOSTED=false ;;
    --self-hosted)   SELF_HOSTED=true ;;
    --no-cleanup)    AUTO_CLEANUP=false ;;
    *) echo "Unknown argument: $arg" >&2
       echo "Usage: $0 [--github-hosted] [--no-cleanup]" >&2
       exit 1 ;;
  esac
done

# Verify monorepo exists
if [ ! -d "$MONOREPO" ]; then
  echo "ERROR: Monorepo not found at $MONOREPO"
  echo "  Run demo/setup.sh first, or set MONOREPO_DIR to the correct path."
  exit 1
fi

echo "=== Agent Blueprints Demo ==="
if $SELF_HOSTED; then
  echo "Mode: self-hosted runner (local env vars, no GitHub secrets needed)"
else
  echo "Mode: GitHub-hosted runner (requires GitHub secrets — see DEMO_GUIDE.md)"
  echo "WARNING: Without --self-hosted, the investigate workflow requires GitHub secrets"
  echo "         (ANTHROPIC_API_KEY, SOURCEGRAPH_ACCESS_TOKEN) configured on the monorepo."
  echo "         Use --self-hosted (default) to use your local env vars instead."
fi
echo ""

# ─────────────────────────────────────────────────────────────
# Self-hosted mode: start the runner before pushing
# ─────────────────────────────────────────────────────────────
RUNNER_STARTED=false
if $SELF_HOSTED; then
  echo "[Phase 1/4] Starting self-hosted runner..."
  bash "$SCRIPT_DIR/setup_runner.sh" --background
  echo ""
  echo "  Waiting for runner to connect to GitHub..."
  sleep 5
  RUNNER_STARTED=true
  echo ""
fi

# ─────────────────────────────────────────────────────────────
# Trigger CI by pushing failure branch
# ─────────────────────────────────────────────────────────────
if $SELF_HOSTED; then
  echo "[Phase 2/4] Triggering CI failure..."
else
  echo "[Phase 1/3] Triggering CI failure..."
fi
echo "  Creating branch $TRIGGER_BRANCH from demo/ci-failure-001..."
cd "$MONOREPO"
git fetch origin demo/ci-failure-001 2>/dev/null || true
git checkout demo/ci-failure-001 2>/dev/null
git checkout -b "$TRIGGER_BRANCH" 2>/dev/null
git push origin "$TRIGGER_BRANCH" 2>/dev/null
COMMIT_SHA=$(git rev-parse HEAD)

echo ""
echo "  Pushed $TRIGGER_BRANCH (commit ${COMMIT_SHA:0:8})"
echo "  Monitor: https://github.com/sg-evals/agent-blueprints-demo-monorepo/actions"
echo ""

# ─────────────────────────────────────────────────────────────
# Wait phases with progress
# ─────────────────────────────────────────────────────────────
if $SELF_HOSTED; then
  echo "[Phase 3/4] CI Fast running on ubuntu-latest (~30s)..."
else
  echo "[Phase 2/3] CI Fast running on ubuntu-latest (~30s)..."
fi
echo "  Waiting for CI to fail on TestRetryBackoffZero..."
echo ""

# Poll for CI run completion, then wait for investigation
if $SELF_HOSTED; then
  echo "[Phase 4/4] Agent investigating (self-hosted runner)..."
  echo "  Expected: CI ~30s + trigger delay ~60s + investigation ~90s = 2-4 minutes total"
else
  echo "[Phase 3/3] Agent investigating (GitHub-hosted runner)..."
  echo "  Expected: CI ~30s + trigger delay ~60s + investigation ~90s = 2-4 minutes total"
fi
echo ""
echo "  Watching for investigation comment on commit ${COMMIT_SHA:0:8}..."

COMMENT_FOUND=false
ELAPSED=0
MAX_WAIT=360  # 6 minutes
POLL_INTERVAL=5

# Show progress dots with phase labels
CI_DONE_LOGGED=false
TRIGGER_DONE_LOGGED=false

while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  COMMENTS=$(gh api "repos/sg-evals/agent-blueprints-demo-monorepo/commits/$COMMIT_SHA/comments" \
    --jq 'length' 2>/dev/null || echo "0")

  if [ "$COMMENTS" -gt 0 ]; then
    echo ""
    echo ""
    echo "  Investigation comment posted! (${ELAPSED}s elapsed)"
    COMMENT_FOUND=true
    break
  fi

  # Progress indicators based on elapsed time
  if [ "$ELAPSED" -lt 45 ]; then
    if [ "$CI_DONE_LOGGED" = false ] && [ "$ELAPSED" -gt 0 ] && [ $((ELAPSED % 10)) -eq 0 ]; then
      printf "\r  CI Fast running... (~%ds)" "$ELAPSED"
    fi
  elif [ "$ELAPSED" -lt 120 ]; then
    if [ "$CI_DONE_LOGGED" = false ]; then
      echo ""
      printf "  CI failed. Waiting for workflow_run trigger..."
      CI_DONE_LOGGED=true
    else
      printf "."
    fi
  else
    if [ "$TRIGGER_DONE_LOGGED" = false ]; then
      echo ""
      printf "  Investigate workflow triggered. Agent investigating..."
      TRIGGER_DONE_LOGGED=true
    else
      printf "."
    fi
  fi

  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

echo ""
echo ""

# ─────────────────────────────────────────────────────────────
# Show result
# ─────────────────────────────────────────────────────────────
if $COMMENT_FOUND; then
  echo "=== Investigation Result ==="
  echo ""
  gh api "repos/sg-evals/agent-blueprints-demo-monorepo/commits/$COMMIT_SHA/comments" \
    --jq '.[0].body' 2>/dev/null
  echo ""
else
  echo "Timed out after ${MAX_WAIT}s waiting for investigation comment."
  echo ""
  echo "Check workflow status at:"
  echo "  https://github.com/sg-evals/agent-blueprints-demo-monorepo/actions"
  echo ""
  echo "Common causes:"
  echo "  - Runner was offline when CI Fast completed (push another trigger branch to retry)"
  echo "  - investigate.yml on main doesn't have runs-on: [self-hosted, demo-runner]"
  echo "  - API key or token issue (run demo/preflight.sh to diagnose)"
fi

# ─────────────────────────────────────────────────────────────
# Cleanup: delete trigger branch
# ─────────────────────────────────────────────────────────────
if $AUTO_CLEANUP; then
  echo ""
  echo "Cleaning up trigger branch $TRIGGER_BRANCH..."
  git push origin --delete "$TRIGGER_BRANCH" 2>/dev/null && echo "  Deleted." || echo "  (already gone)"
fi

# ─────────────────────────────────────────────────────────────
# Self-hosted mode: tear down runner
# ─────────────────────────────────────────────────────────────
if $RUNNER_STARTED; then
  echo ""
  echo "Tearing down self-hosted runner..."
  bash "$SCRIPT_DIR/teardown_runner.sh"
fi

echo ""
echo "Demo complete."
