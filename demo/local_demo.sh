#!/bin/bash
# Full local demo: runs the investigation agent against the demo monorepo.
#
# This demonstrates:
#   1. CI failure detection (runs failing test locally)
#   2. Claude Code agent investigation via Sourcegraph MCP
#   3. Investigation output with root-cause analysis
#
# Prerequisites:
#   SOURCEGRAPH_ACCESS_TOKEN - for MCP tools
#   ANTHROPIC_API_KEY        - for Claude Code
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MONOREPO="${MONOREPO_DIR:-$AGENT_DIR/../agent-blueprints-demo-monorepo}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

header() { echo -e "\n${BLUE}=== $1 ===${NC}\n"; }
step()   { echo -e "${YELLOW}[$1]${NC} $2"; }
ok()     { echo -e "${GREEN}  -> $1${NC}"; }

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Agent Blueprints Demo — Sourcegraph Deep Search + MCP ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ─────────────────────────────────────────────────────────────
# Step 1: Show baseline passes
# ─────────────────────────────────────────────────────────────
header "Step 1: Baseline Branch — All Tests Pass"
step "1a" "Switching to demo/baseline..."
cd "$MONOREPO"
git checkout demo/baseline 2>/dev/null

step "1b" "Running tests on baseline..."
if bash platform/ci-tools/test-all.sh > /tmp/baseline-tests.log 2>&1; then
  ok "All 14 modules pass on baseline"
else
  echo -e "${RED}Baseline tests failed (unexpected)${NC}"
  exit 1
fi

# ─────────────────────────────────────────────────────────────
# Step 2: Show CI failure
# ─────────────────────────────────────────────────────────────
header "Step 2: CI Failure Branch — TestRetryBackoffZero Fails"
step "2a" "Switching to demo/ci-failure-001..."
git checkout demo/ci-failure-001 2>/dev/null

step "2b" "Running failing test..."
echo ""
cd apps/worker-reconcile
if go test -v -run TestRetryBackoffZero -count=1 ./... 2>&1; then
  echo -e "${RED}Test passed (expected failure)${NC}"
  exit 1
else
  echo ""
  ok "TestRetryBackoffZero FAILS as expected"
  ok "Error: invalid negative backoff delay: -100ms"
fi
cd "$MONOREPO"

step "2c" "Regression diff:"
echo ""
git diff demo/baseline demo/ci-failure-001 -- libs/retry/backoff.go
echo ""

# ─────────────────────────────────────────────────────────────
# Step 3: Run the investigation agent
# ─────────────────────────────────────────────────────────────
header "Step 3: Background Agent — Claude Code + Sourcegraph MCP"

if [ -z "${SOURCEGRAPH_ACCESS_TOKEN:-}" ]; then
  echo -e "${YELLOW}SOURCEGRAPH_ACCESS_TOKEN not set — skipping live agent.${NC}"
  echo ""
  echo "To run the live agent:"
  echo "  export SOURCEGRAPH_ACCESS_TOKEN='sgp_...'"
  echo "  export ANTHROPIC_API_KEY='sk-ant-...'"
  echo "  bash demo/local_demo.sh"
  echo ""
  echo "Showing expected output instead:"
  echo ""
  cat <<'EOF'
## Automated Investigation

**Failing test:**
`TestRetryBackoffZero`

**Likely root cause:**
TestRetryBackoffZero fails because the backoff calculation produces a negative
duration. The function `RetryBackoff` in `libs/retry/backoff.go` was simplified
from exponential to linear backoff using `(attempt-1) * baseDelay`, but the
attempt-clamping guard (`if attempt < 1`) was removed. When `attempt=0`, the
formula yields `-1 * baseDelay = -100ms`.

**Relevant files:**
- `libs/retry/backoff.go` — removed attempt clamp, changed to linear formula
- `libs/retry/backoff_test.go` — removed TestRetryBackoffClampsZeroAttempt
- `apps/worker-reconcile/reconcile.go` — calls RetryBackoff
- `apps/worker-reconcile/reconcile_test.go` — TestRetryBackoffZero catches the bug

**Suggested fix:**
Restore the attempt clamp: `if attempt < 1 { attempt = 1 }` before the delay
calculation, or switch back to exponential backoff.

**Confidence:**
Medium
EOF
else
  step "3a" "Launching Claude Code with Sourcegraph MCP tools..."
  echo ""

  cd "$AGENT_DIR"
  # Clean any previous output
  rm -f investigation_output.md

  bash investigate.sh \
    --repo "sg-evals/agent-blueprints-demo-monorepo" \
    --test "TestRetryBackoffZero" \
    --error "attempt 0 produced invalid backoff: invalid negative backoff delay: -100ms"

  echo ""
fi

# ─────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────
header "Cleanup"
cd "$MONOREPO"
git checkout main 2>/dev/null
ok "Monorepo restored to main branch"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    Demo Complete!                        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "What happened:"
echo "  1. Baseline branch passes all 14 module tests"
echo "  2. CI failure branch fails on TestRetryBackoffZero (-100ms)"
echo "  3. Claude Code agent investigated via Sourcegraph MCP tools"
echo "  4. Agent produced root-cause analysis identifying libs/retry/backoff.go"
echo ""
echo "In the automated flow (GitHub Actions):"
echo "  CI fails → investigate.yml triggers → Claude Code + MCP → GitHub comment"
echo ""
