#!/bin/bash
# One-command setup: clone repos, validate layout, check credentials, optionally register runner.
#
# Usage:
#   bash demo/setup.sh                    # Interactive setup
#   bash demo/setup.sh --register-runner  # Also register self-hosted runner
#   bash demo/setup.sh --check-only       # Run preflight, don't clone or register
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT_DIR="$(cd "$AGENT_DIR/.." && pwd)"

REGISTER_RUNNER=false
CHECK_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --register-runner) REGISTER_RUNNER=true ;;
    --check-only)      CHECK_ONLY=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

echo "=== Agent Blueprints Demo — Setup ==="
echo ""

# ─────────────────────────────────────────────────────────────
# Source .env if present
# ─────────────────────────────────────────────────────────────
ENV_FILE="$SCRIPT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  echo "Loading credentials from demo/.env..."
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
  echo ""
fi

# ─────────────────────────────────────────────────────────────
# Step 1: Clone companion monorepo (if not present)
# ─────────────────────────────────────────────────────────────
MONOREPO="$PARENT_DIR/agent-blueprints-demo-monorepo"

if [ "$CHECK_ONLY" = false ]; then
  if [ ! -d "$MONOREPO" ]; then
    echo "Cloning companion monorepo..."
    git clone https://github.com/sg-evals/agent-blueprints-demo-monorepo.git "$MONOREPO"
    echo ""
  else
    echo "Companion monorepo already present: $MONOREPO"
    echo ""
  fi
fi

# ─────────────────────────────────────────────────────────────
# Step 2: Validate directory layout
# ─────────────────────────────────────────────────────────────
echo "Validating directory layout..."
echo "  agent-blueprints-demo:          $AGENT_DIR"
echo "  agent-blueprints-demo-monorepo: $MONOREPO"
echo ""

if [ ! -d "$MONOREPO" ]; then
  echo "ERROR: Monorepo not found at $MONOREPO"
  echo "  Both repos must be siblings in the same directory."
  echo "  Run without --check-only to clone automatically, or:"
  echo "    git clone https://github.com/sg-evals/agent-blueprints-demo-monorepo.git $MONOREPO"
  exit 1
fi

# Check they're siblings
AGENT_PARENT="$(dirname "$AGENT_DIR")"
MONO_PARENT="$(dirname "$MONOREPO")"
if [ "$AGENT_PARENT" != "$MONO_PARENT" ]; then
  echo "ERROR: Repos are not in the same parent directory."
  echo "  agent-blueprints-demo parent:          $AGENT_PARENT"
  echo "  agent-blueprints-demo-monorepo parent: $MONO_PARENT"
  echo ""
  echo "  Both repos must be siblings. Set MONOREPO_DIR to override:"
  echo "    export MONOREPO_DIR=/path/to/agent-blueprints-demo-monorepo"
  exit 1
fi

echo "Directory layout OK."
echo ""

# ─────────────────────────────────────────────────────────────
# Step 3: Run preflight check
# ─────────────────────────────────────────────────────────────
echo "Running preflight check..."
echo ""
if MONOREPO_DIR="$MONOREPO" bash "$SCRIPT_DIR/preflight.sh"; then
  PREFLIGHT_OK=true
else
  PREFLIGHT_OK=false
fi
echo ""

if [ "$PREFLIGHT_OK" = false ]; then
  echo "Setup cannot continue until preflight issues are resolved."
  echo ""
  echo "Common fixes:"
  echo "  - Missing ANTHROPIC_API_KEY: get it at https://console.anthropic.com"
  echo "  - Missing SOURCEGRAPH_ACCESS_TOKEN: https://sourcegraph.com/user/settings/tokens"
  echo "  - Missing GITHUB_TOKEN: https://github.com/settings/tokens (needs repo + workflow scopes)"
  echo "  - No push access: ask a team admin to add you to sg-evals/agent-blueprints-demo-monorepo"
  echo ""
  echo "Tip: create demo/.env from demo/.env.example and re-run setup.sh."
  exit 1
fi

# ─────────────────────────────────────────────────────────────
# Step 4: Optionally register runner
# ─────────────────────────────────────────────────────────────
if [ "$REGISTER_RUNNER" = true ]; then
  echo "Registering self-hosted runner..."
  bash "$SCRIPT_DIR/setup_runner.sh"
  echo ""
fi

# ─────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────
echo "=== Setup complete ==="
echo ""
echo "To run the demo:"
echo "  ./demo/run_demo.sh"
echo ""
if [ "$REGISTER_RUNNER" = false ]; then
  echo "The runner will be started automatically when you run the demo."
  echo "Or register it now:  bash demo/setup.sh --register-runner"
  echo ""
fi
