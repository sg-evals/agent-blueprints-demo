#!/bin/bash
# Preflight check: verify all prerequisites before running the demo.
set -euo pipefail

PASS=0
FAIL=0
WARN=0

check() {
  local desc="$1"
  local cmd="$2"
  printf "  %-50s" "$desc"
  if eval "$cmd" > /dev/null 2>&1; then
    echo "OK"
    PASS=$((PASS + 1))
  else
    echo "FAIL"
    FAIL=$((FAIL + 1))
  fi
}

warn_check() {
  local desc="$1"
  local cmd="$2"
  printf "  %-50s" "$desc"
  if eval "$cmd" > /dev/null 2>&1; then
    echo "OK"
    PASS=$((PASS + 1))
  else
    echo "WARN (optional)"
    WARN=$((WARN + 1))
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MONOREPO="${MONOREPO_DIR:-$RUNTIME_DIR/../agent-blueprints-demo-monorepo}"

echo "=== Agent Blueprints Demo — Preflight Check ==="
echo ""

echo "[Tools]"
check "git installed"                    "git --version"
check "go installed (1.22+)"            "go version | grep -E 'go1\.(2[2-9]|[3-9])'"
check "node installed (18+)"            "node --version"
check "npm installed"                   "npm --version"
check "curl installed"                  "curl --version"
warn_check "gh CLI installed"           "gh --version"
warn_check "wrangler installed"         "npx wrangler --version"
echo ""

echo "[Monorepo: $MONOREPO]"
check "monorepo directory exists"       "test -d '$MONOREPO'"
check "go.work exists"                  "test -f '$MONOREPO/go.work'"
check "libs/retry/backoff.go exists"    "test -f '$MONOREPO/libs/retry/backoff.go'"
check "CI workflow exists"              "test -f '$MONOREPO/.github/workflows/ci-fast.yml'"
check "baseline branch exists"         "cd '$MONOREPO' && git rev-parse demo/baseline"
check "ci-failure-001 branch exists"   "cd '$MONOREPO' && git rev-parse demo/ci-failure-001"
echo ""

echo "[Monorepo: Build & Test]"
check "go workspace syncs"             "cd '$MONOREPO' && go work sync"
check "baseline tests pass"            "cd '$MONOREPO' && git checkout demo/baseline 2>/dev/null && bash platform/ci-tools/test-all.sh"
# Restore to main after test
git -C "$MONOREPO" checkout main 2>/dev/null || true
echo ""

echo "[Agent Runtime: $RUNTIME_DIR]"
check "package.json exists"            "test -f '$RUNTIME_DIR/package.json'"
check "node_modules installed"         "test -d '$RUNTIME_DIR/node_modules'"
check "TypeScript compiles"            "cd '$RUNTIME_DIR' && npx tsc --noEmit"
check "vitest tests pass"              "cd '$RUNTIME_DIR' && npx vitest run --reporter=dot"
check "wrangler.toml exists"           "test -f '$RUNTIME_DIR/wrangler.toml'"
check "blueprint.yaml exists"          "test -f '$RUNTIME_DIR/blueprints/ci_failure_investigator/blueprint.yaml'"
echo ""

echo "[Credentials]"
warn_check "GITHUB_TOKEN set"               "test -n '${GITHUB_TOKEN:-}'"
warn_check "SOURCEGRAPH_ACCESS_TOKEN set"   "test -n '${SOURCEGRAPH_ACCESS_TOKEN:-}'"
warn_check "ANTHROPIC_API_KEY set"          "test -n '${ANTHROPIC_API_KEY:-}'"
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
  echo "  Warnings are for optional features (live GitHub/Sourcegraph integration)."
  echo "  The local demo will work without them."
else
  echo "PREFLIGHT PASSED — ready for demo!"
fi
