#!/bin/bash
# Set up a self-hosted GitHub Actions runner for agent-blueprints-demo-monorepo.
#
# Downloads, configures, and optionally starts the runner.
# The runner inherits ANTHROPIC_API_KEY and SOURCEGRAPH_ACCESS_TOKEN from the
# environment, so no GitHub secrets configuration is needed.
#
# Prerequisites:
#   GITHUB_TOKEN  - personal access token with repo admin scope (for runner registration)
#   ANTHROPIC_API_KEY        - for Claude Code (inherited by runner)
#   SOURCEGRAPH_ACCESS_TOKEN - for Sourcegraph MCP (inherited by runner)
#   Go 1.22+
#   claude CLI (npm install -g @anthropic-ai/claude-code)
#   gh CLI
#
# Usage:
#   ./demo/setup_runner.sh [--background]
#
#   --background   Start runner as a background process (default: foreground)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RUNNER_VERSION="2.322.0"
RUNNER_DIR="$HOME/.github-runner-demo"
RUNNER_REPO="sg-evals/agent-blueprints-demo-monorepo"
RUNNER_LABELS="self-hosted,demo-runner"
RUNNER_NAME="${RUNNER_NAME:-demo-runner-$(hostname)}"
BACKGROUND=false

# Parse args
for arg in "$@"; do
  case "$arg" in
    --background) BACKGROUND=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓ $1${NC}"; }
warn() { echo -e "${YELLOW}  ! $1${NC}"; }
fail() { echo -e "${RED}  ✗ $1${NC}"; exit 1; }

echo ""
echo "=== Self-Hosted Runner Setup ==="
echo "  Repo:   $RUNNER_REPO"
echo "  Name:   $RUNNER_NAME"
echo "  Labels: $RUNNER_LABELS"
echo "  Dir:    $RUNNER_DIR"
echo ""

# ─────────────────────────────────────────────────────────────
# 1. Validate prerequisites
# ─────────────────────────────────────────────────────────────
echo "[1/5] Checking prerequisites..."

[[ -n "${GITHUB_TOKEN:-}" ]]              || fail "GITHUB_TOKEN not set (needs repo admin scope for runner registration)"
[[ -n "${ANTHROPIC_API_KEY:-}" ]]         || fail "ANTHROPIC_API_KEY not set (required for Claude Code)"
[[ -n "${SOURCEGRAPH_ACCESS_TOKEN:-}" ]]  || fail "SOURCEGRAPH_ACCESS_TOKEN not set (required for Sourcegraph MCP)"

go version | grep -qE 'go1\.(2[2-9]|[3-9][0-9])' || fail "Go 1.22+ required (run: go version)"
command -v claude >/dev/null              || fail "claude CLI not installed (run: npm install -g @anthropic-ai/claude-code)"
command -v gh >/dev/null                  || fail "gh CLI not installed (see https://cli.github.com)"

ok "All prerequisites satisfied"

# ─────────────────────────────────────────────────────────────
# 2. Detect platform and set download URL
# ─────────────────────────────────────────────────────────────
echo ""
echo "[2/5] Detecting platform..."

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Linux)
    case "$ARCH" in
      x86_64)  RUNNER_ARCH="linux-x64" ;;
      aarch64) RUNNER_ARCH="linux-arm64" ;;
      *)       fail "Unsupported Linux architecture: $ARCH" ;;
    esac
    RUNNER_EXT="tar.gz"
    ;;
  Darwin)
    case "$ARCH" in
      x86_64) RUNNER_ARCH="osx-x64" ;;
      arm64)  RUNNER_ARCH="osx-arm64" ;;
      *)      fail "Unsupported macOS architecture: $ARCH" ;;
    esac
    RUNNER_EXT="tar.gz"
    ;;
  *)
    fail "Unsupported OS: $OS"
    ;;
esac

RUNNER_PKG="actions-runner-${RUNNER_ARCH}-${RUNNER_VERSION}.${RUNNER_EXT}"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_PKG}"
ok "Platform: $RUNNER_ARCH"

# ─────────────────────────────────────────────────────────────
# 3. Download runner (idempotent — skip if already present)
# ─────────────────────────────────────────────────────────────
echo ""
echo "[3/5] Installing runner binary..."

mkdir -p "$RUNNER_DIR"

if [[ -x "$RUNNER_DIR/run.sh" ]]; then
  INSTALLED_VERSION=$("$RUNNER_DIR/run.sh" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
  if [[ "$INSTALLED_VERSION" == "$RUNNER_VERSION" ]]; then
    ok "Runner $RUNNER_VERSION already installed at $RUNNER_DIR (skipping download)"
  else
    warn "Installed version ($INSTALLED_VERSION) != desired ($RUNNER_VERSION), re-downloading..."
    rm -f "$RUNNER_DIR/run.sh"
  fi
fi

if [[ ! -x "$RUNNER_DIR/run.sh" ]]; then
  echo "  Downloading $RUNNER_PKG..."
  curl -sL "$RUNNER_URL" -o "/tmp/$RUNNER_PKG"
  tar xzf "/tmp/$RUNNER_PKG" -C "$RUNNER_DIR"
  rm -f "/tmp/$RUNNER_PKG"
  ok "Runner downloaded and extracted to $RUNNER_DIR"
fi

# ─────────────────────────────────────────────────────────────
# 4. Register runner with GitHub
# ─────────────────────────────────────────────────────────────
echo ""
echo "[4/5] Registering runner with GitHub..."

# Check if already configured (idempotent)
if [[ -f "$RUNNER_DIR/.runner" ]]; then
  CONFIGURED_REPO=$(python3 -c "import json; d=json.load(open('$RUNNER_DIR/.runner')); print(d.get('gitHubUrl',''))" 2>/dev/null || echo "")
  if echo "$CONFIGURED_REPO" | grep -q "$RUNNER_REPO"; then
    ok "Runner already configured for $RUNNER_REPO (skipping registration)"
  else
    warn "Runner configured for different repo ($CONFIGURED_REPO), re-registering..."
    cd "$RUNNER_DIR" && ./config.sh remove --token "$(gh api "repos/$RUNNER_REPO/actions/runners/registration-token" --method POST --jq '.token')" 2>/dev/null || true
    rm -f "$RUNNER_DIR/.runner" "$RUNNER_DIR/.credentials"
  fi
fi

if [[ ! -f "$RUNNER_DIR/.runner" ]]; then
  REG_TOKEN=$(gh api "repos/$RUNNER_REPO/actions/runners/registration-token" \
    --method POST \
    --header "Authorization: Bearer $GITHUB_TOKEN" \
    --jq '.token')

  cd "$RUNNER_DIR"
  ./config.sh \
    --url "https://github.com/$RUNNER_REPO" \
    --token "$REG_TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS" \
    --work "_work" \
    --unattended \
    --replace
  ok "Runner registered as '$RUNNER_NAME' with labels: $RUNNER_LABELS"
fi

# ─────────────────────────────────────────────────────────────
# 5. Start runner
# ─────────────────────────────────────────────────────────────
echo ""
echo "[5/5] Starting runner..."

cd "$RUNNER_DIR"

if $BACKGROUND; then
  # Pass through API keys to runner process
  env ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
      SOURCEGRAPH_ACCESS_TOKEN="$SOURCEGRAPH_ACCESS_TOKEN" \
      GITHUB_TOKEN="$GITHUB_TOKEN" \
      nohup ./run.sh > "$RUNNER_DIR/runner.log" 2>&1 &
  RUNNER_PID=$!
  echo "$RUNNER_PID" > "$RUNNER_DIR/runner.pid"
  ok "Runner started in background (PID $RUNNER_PID)"
  echo ""
  echo "  Logs:    $RUNNER_DIR/runner.log"
  echo "  PID:     $RUNNER_DIR/runner.pid"
  echo "  Stop:    ./demo/teardown_runner.sh"
else
  echo "  Starting runner in foreground (Ctrl-C to stop)..."
  echo ""
  exec env ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
           SOURCEGRAPH_ACCESS_TOKEN="$SOURCEGRAPH_ACCESS_TOKEN" \
           GITHUB_TOKEN="$GITHUB_TOKEN" \
           ./run.sh
fi
