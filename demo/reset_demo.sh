#!/bin/bash
# Reset the demo environment to baseline state.
set -euo pipefail

MONOREPO="${MONOREPO_DIR:-../agent-blueprints-demo-monorepo}"

echo "=== Resetting Demo ==="

cd "$MONOREPO"

# Delete any trigger branches
echo "Cleaning up trigger branches..."
for branch in $(git branch -r | grep 'origin/demo/trigger-' | sed 's/origin\///'); do
  echo "  Deleting $branch"
  git push origin --delete "$branch" 2>/dev/null || true
done

# Ensure baseline is clean
echo "Verifying baseline branch..."
git checkout demo/baseline 2>/dev/null
git push origin demo/baseline 2>/dev/null || true

# Ensure failure scenario branch exists
echo "Verifying failure scenario branch..."
git checkout demo/ci-failure-001 2>/dev/null
git push origin demo/ci-failure-001 2>/dev/null || true

git checkout main 2>/dev/null

echo ""
echo "Demo reset complete."
echo "Ready to run: ./demo/run_demo.sh"
