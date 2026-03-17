#!/bin/bash
# Tear down the self-hosted GitHub Actions demo runner.
#
# Stops the runner process and deregisters it from GitHub.
# Safe to run even if the runner is not currently running.
#
# Prerequisites:
#   GITHUB_TOKEN - personal access token with repo admin scope
#
# Usage:
#   ./demo/teardown_runner.sh
set -euo pipefail

RUNNER_DIR="$HOME/.github-runner-demo"
RUNNER_REPO="sg-evals/agent-blueprints-demo-monorepo"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓ $1${NC}"; }
warn() { echo -e "${YELLOW}  ! $1${NC}"; }

echo ""
echo "=== Self-Hosted Runner Teardown ==="
echo "  Dir:  $RUNNER_DIR"
echo "  Repo: $RUNNER_REPO"
echo ""

# ─────────────────────────────────────────────────────────────
# 1. Stop runner process (if running in background)
# ─────────────────────────────────────────────────────────────
echo "[1/3] Stopping runner process..."

PID_FILE="$RUNNER_DIR/runner.pid"
if [[ -f "$PID_FILE" ]]; then
  PID=$(cat "$PID_FILE")
  if kill -0 "$PID" 2>/dev/null; then
    kill "$PID"
    # Wait up to 10s for graceful shutdown
    for i in $(seq 1 10); do
      kill -0 "$PID" 2>/dev/null || break
      sleep 1
    done
    # Force kill if still running
    kill -0 "$PID" 2>/dev/null && kill -9 "$PID" || true
    ok "Stopped runner (PID $PID)"
  else
    warn "PID $PID not running (already stopped)"
  fi
  rm -f "$PID_FILE"
else
  # No pid file — try to find and stop any running runner process
  RUNNER_PIDS=$(pgrep -f "$RUNNER_DIR/run.sh" 2>/dev/null || true)
  if [[ -n "$RUNNER_PIDS" ]]; then
    echo "$RUNNER_PIDS" | xargs kill 2>/dev/null || true
    ok "Stopped runner processes: $RUNNER_PIDS"
  else
    warn "No running runner process found (nothing to stop)"
  fi
fi

# ─────────────────────────────────────────────────────────────
# 2. Deregister from GitHub
# ─────────────────────────────────────────────────────────────
echo ""
echo "[2/3] Deregistering from GitHub..."

if [[ ! -d "$RUNNER_DIR" ]]; then
  warn "Runner directory not found — already cleaned up"
elif [[ ! -f "$RUNNER_DIR/.runner" ]]; then
  warn "Runner not configured — nothing to deregister"
else
  TOKEN="${GITHUB_TOKEN:-}"
  if [[ -z "$TOKEN" ]]; then
    warn "GITHUB_TOKEN not set — skipping GitHub deregistration"
    warn "You may need to manually remove the runner from:"
    warn "  https://github.com/$RUNNER_REPO/settings/actions/runners"
  else
    REMOVE_TOKEN=$(gh api "repos/$RUNNER_REPO/actions/runners/remove-token" \
      --method POST \
      --header "Authorization: Bearer $TOKEN" \
      --jq '.token' 2>/dev/null || echo "")

    if [[ -n "$REMOVE_TOKEN" ]]; then
      cd "$RUNNER_DIR"
      ./config.sh remove --token "$REMOVE_TOKEN" --unattended 2>/dev/null && \
        ok "Runner deregistered from GitHub" || \
        warn "Deregistration command failed — runner may have already been removed"
    else
      warn "Could not get removal token — runner may still appear in GitHub settings"
      warn "Remove manually at: https://github.com/$RUNNER_REPO/settings/actions/runners"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────
# 3. Clean up runner directory
# ─────────────────────────────────────────────────────────────
echo ""
echo "[3/3] Cleaning up runner directory..."

if [[ -d "$RUNNER_DIR" ]]; then
  rm -rf "$RUNNER_DIR"
  ok "Removed $RUNNER_DIR"
else
  warn "Runner directory already removed"
fi

echo ""
echo "Teardown complete."
