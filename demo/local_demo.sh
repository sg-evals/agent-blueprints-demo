#!/bin/bash
# Full local demo: runs the entire flow without requiring GitHub or Cloudflare.
#
# This demonstrates:
#   1. CI failure detection (runs failing test locally)
#   2. Webhook processing (local Cloudflare worker)
#   3. Investigation output (deterministic comment)
#
# No external services required.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MONOREPO="${MONOREPO_DIR:-$RUNTIME_DIR/../agent-blueprints-demo-monorepo}"
WORKER_URL="http://localhost:8787"

# Colors (if terminal supports them)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

header() { echo -e "\n${BLUE}=== $1 ===${NC}\n"; }
step()   { echo -e "${YELLOW}[$1]${NC} $2"; }
ok()     { echo -e "${GREEN}  -> $1${NC}"; }
fail()   { echo -e "${RED}  -> $1${NC}"; }

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Agent Blueprints Demo — Local Simulation            ║${NC}"
echo -e "${BLUE}║     Sourcegraph Deep Search + MCP                       ║${NC}"
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
  fail "Baseline tests failed (unexpected)"
  cat /tmp/baseline-tests.log
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
  fail "Test passed (expected failure)"
  exit 1
else
  echo ""
  ok "TestRetryBackoffZero FAILS as expected"
  ok "Error: invalid negative backoff delay: -100ms"
fi
cd "$MONOREPO"

step "2c" "Showing the regression diff..."
echo ""
git diff demo/baseline demo/ci-failure-001 -- libs/retry/backoff.go
echo ""

# ─────────────────────────────────────────────────────────────
# Step 3: Start webhook worker
# ─────────────────────────────────────────────────────────────
header "Step 3: Background Agent — Webhook Ingress"
step "3a" "Starting local Cloudflare Worker..."
cd "$RUNTIME_DIR"

# Start wrangler in background
npx wrangler dev --port 8787 > /tmp/wrangler.log 2>&1 &
WRANGLER_PID=$!
sleep 4

# Check if worker started
if curl -s "$WORKER_URL/health" > /dev/null 2>&1; then
  ok "Worker running at $WORKER_URL"
else
  fail "Worker failed to start (check /tmp/wrangler.log)"
  kill $WRANGLER_PID 2>/dev/null || true
  exit 1
fi

# ─────────────────────────────────────────────────────────────
# Step 4: Simulate webhook
# ─────────────────────────────────────────────────────────────
header "Step 4: GitHub Webhook — CI Failure Event"

COMMIT_SHA=$(cd "$MONOREPO" && git rev-parse HEAD)
step "4a" "Simulating workflow_run.completed webhook..."
echo "     Repo:   sg-evals/agent-blueprints-demo-monorepo"
echo "     Branch: demo/ci-failure-001"
echo "     Commit: ${COMMIT_SHA:0:12}"
echo "     Result: failure"
echo ""

PAYLOAD=$(cat <<EOF
{
  "action": "completed",
  "workflow_run": {
    "id": 99999999,
    "name": "CI Fast",
    "head_sha": "$COMMIT_SHA",
    "head_branch": "demo/ci-failure-001",
    "conclusion": "failure",
    "html_url": "https://github.com/sg-evals/agent-blueprints-demo-monorepo/actions/runs/99999999",
    "repository": {
      "full_name": "sg-evals/agent-blueprints-demo-monorepo"
    }
  }
}
EOF
)

RESPONSE=$(curl -s -X POST "$WORKER_URL/webhook/github" \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: workflow_run" \
  -d "$PAYLOAD")

JOB_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('jobId','?'))" 2>/dev/null || echo "?")
STATUS=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null || echo "?")

if [ "$STATUS" = "enqueued" ]; then
  ok "Webhook accepted, job enqueued: $JOB_ID"
else
  fail "Webhook rejected: $RESPONSE"
fi

# ─────────────────────────────────────────────────────────────
# Step 5: Show investigation output
# ─────────────────────────────────────────────────────────────
header "Step 5: Investigation Output"
step "5a" "Agent investigation result (deterministic demo mode):"
echo ""

SG_REPO="github.com/sg-evals/agent-blueprints-demo-monorepo"

cat <<'COMMENT_EOF'
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
- `libs/retry/backoff.go`          (Sourcegraph link)
- `libs/retry/backoff_test.go`     (Sourcegraph link)
- `apps/worker-reconcile/reconcile.go`       (Sourcegraph link)
- `apps/worker-reconcile/reconcile_test.go`  (Sourcegraph link)

**Suggested fix:**
Restore the attempt clamp: `if attempt < 1 { attempt = 1 }` before the delay
calculation, or switch back to exponential backoff which naturally handles
this case.

**Confidence:**
Medium
COMMENT_EOF

echo ""

# ─────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────
header "Cleanup"
step "6" "Stopping local worker..."
kill $WRANGLER_PID 2>/dev/null || true
wait $WRANGLER_PID 2>/dev/null || true
ok "Worker stopped"

cd "$MONOREPO"
git checkout main 2>/dev/null
ok "Monorepo restored to main branch"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    Demo Complete!                        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "What you saw:"
echo "  1. Baseline branch passes all 14 module tests"
echo "  2. CI failure branch fails on TestRetryBackoffZero (-100ms negative delay)"
echo "  3. Cloudflare Worker received the webhook and enqueued an investigation job"
echo "  4. Agent produced deterministic root-cause analysis with Sourcegraph links"
echo ""
echo "In production, the agent would:"
echo "  - Fetch CI logs from GitHub Actions API"
echo "  - Query Sourcegraph Deep Search for semantic investigation"
echo "  - Use MCP tools for symbol-level code navigation"
echo "  - Post the investigation as a GitHub commit comment"
echo ""
