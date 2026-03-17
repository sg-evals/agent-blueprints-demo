#!/bin/bash
# Preflight check: verify all prerequisites before running the demo.
set -euo pipefail

PASS=0
FAIL=0
WARN=0

check() {
  local desc="$1"; local cmd="$2"
  printf "  %-55s" "$desc"
  if eval "$cmd" > /dev/null 2>&1; then echo "OK"; PASS=$((PASS + 1))
  else echo "FAIL"; FAIL=$((FAIL + 1)); fi
}

warn_check() {
  local desc="$1"; local cmd="$2"
  printf "  %-55s" "$desc"
  if eval "$cmd" > /dev/null 2>&1; then echo "OK"; PASS=$((PASS + 1))
  else echo "WARN (optional for local fallback)"; WARN=$((WARN + 1)); fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MONOREPO="${MONOREPO_DIR:-$AGENT_DIR/../agent-blueprints-demo-monorepo}"

# Source .env if present
ENV_FILE="$SCRIPT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

echo "=== Agent Blueprints Demo — Preflight Check ==="
echo ""

echo "[Tools]"
check "git installed"                    "git --version"
check "go installed (1.22+)"            "go version | grep -E 'go1\.(2[2-9]|[3-9])'"
warn_check "claude CLI installed"       "command -v claude"
warn_check "gh CLI installed"           "gh --version"
echo ""

echo "[Monorepo: $MONOREPO]"
check "monorepo directory exists"       "test -d '$MONOREPO'"
check "go.work exists"                  "test -f '$MONOREPO/go.work'"
check "libs/retry/backoff.go exists"    "test -f '$MONOREPO/libs/retry/backoff.go'"
check "CI workflow exists"              "test -f '$MONOREPO/.github/workflows/ci-fast.yml'"
check "baseline branch exists"         "cd '$MONOREPO' && git rev-parse demo/baseline"
check "ci-failure-001 branch exists"   "cd '$MONOREPO' && git rev-parse demo/ci-failure-001"
echo ""

echo "[Agent Runtime: $AGENT_DIR]"
check ".mcp.json exists"               "test -f '$AGENT_DIR/.mcp.json'"
check "CLAUDE.md exists"               "test -f '$AGENT_DIR/CLAUDE.md'"
check "investigate.sh exists"          "test -f '$AGENT_DIR/investigate.sh'"
check ".claude/settings.json exists"   "test -f '$AGENT_DIR/.claude/settings.json'"
check "blueprint.yaml exists"          "test -f '$AGENT_DIR/blueprints/ci_failure_investigator/blueprint.yaml'"
echo ""

echo "[Credentials]"
warn_check "SOURCEGRAPH_ACCESS_TOKEN set"   "test -n '${SOURCEGRAPH_ACCESS_TOKEN:-}'"
warn_check "ANTHROPIC_API_KEY set"          "test -n '${ANTHROPIC_API_KEY:-}'"
warn_check "GITHUB_TOKEN set"               "test -n '${GITHUB_TOKEN:-}'"
echo ""

echo "[GitHub Access]"
if [ -n "${GITHUB_TOKEN:-}" ] && command -v gh > /dev/null 2>&1; then
  # Check push access to monorepo
  printf "  %-55s" "push access to sg-evals/agent-blueprints-demo-monorepo"
  GH_USERNAME=$(gh api user --jq '.login' 2>/dev/null || echo "")
  if [ -n "$GH_USERNAME" ]; then
    PERM=$(gh api "repos/sg-evals/agent-blueprints-demo-monorepo/collaborators/$GH_USERNAME/permission" \
      --jq '.permission' 2>/dev/null || echo "none")
    if [ "$PERM" = "admin" ] || [ "$PERM" = "maintain" ] || [ "$PERM" = "write" ]; then
      echo "OK ($PERM)"
      PASS=$((PASS + 1))
    else
      echo "FAIL (permission: ${PERM:-none} — ask a team admin to add you)"
      FAIL=$((FAIL + 1))
    fi
  else
    echo "WARN (could not determine username — check GITHUB_TOKEN)"
    WARN=$((WARN + 1))
  fi

  # Check investigate.yml is on main with self-hosted runner
  printf "  %-55s" "investigate.yml on main uses self-hosted runner"
  INVESTIGATE_YML=$(gh api \
    "repos/sg-evals/agent-blueprints-demo-monorepo/contents/.github/workflows/investigate.yml" \
    --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  if echo "$INVESTIGATE_YML" | grep -q "self-hosted" 2>/dev/null; then
    echo "OK"
    PASS=$((PASS + 1))
  elif [ -z "$INVESTIGATE_YML" ]; then
    echo "WARN (could not read investigate.yml from main)"
    WARN=$((WARN + 1))
  else
    echo "FAIL (investigate.yml on main doesn't use self-hosted runner)"
    echo "       workflow_run only fires from the main branch workflow."
    echo "       Push the updated investigate.yml to main first."
    FAIL=$((FAIL + 1))
  fi
else
  printf "  %-55s" "push access check"
  echo "SKIP (GITHUB_TOKEN not set or gh not installed)"
  WARN=$((WARN + 1))
  printf "  %-55s" "investigate.yml on main check"
  echo "SKIP (GITHUB_TOKEN not set or gh not installed)"
  WARN=$((WARN + 1))
fi
echo ""

echo "=== Results ==="
echo "  Passed:   $PASS"
echo "  Failed:   $FAIL"
echo "  Warnings: $WARN"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "PREFLIGHT FAILED — fix the above issues before running the demo."
  exit 1
fi

if [ "$WARN" -gt 0 ]; then
  echo "PREFLIGHT PASSED with warnings."
  echo "  Set SOURCEGRAPH_ACCESS_TOKEN + ANTHROPIC_API_KEY for live MCP investigation."
  echo "  Without them, the demo shows expected output instead."
else
  echo "PREFLIGHT PASSED — ready for live demo!"
fi
