#!/bin/bash
# Run the deterministic demo: push a CI-failure commit and watch the agent investigate.
set -euo pipefail

MONOREPO="${MONOREPO_DIR:-../agent-blueprints-demo-monorepo}"
BRANCH_SUFFIX="$(date +%s)"
TRIGGER_BRANCH="demo/trigger-${BRANCH_SUFFIX}"

echo "=== Agent Blueprints Demo ==="
echo ""
echo "Step 1: Creating trigger branch from demo/ci-failure-001..."
cd "$MONOREPO"
git checkout demo/ci-failure-001 2>/dev/null
git checkout -b "$TRIGGER_BRANCH" 2>/dev/null

echo ""
echo "Step 2: Pushing to trigger CI..."
git push origin "$TRIGGER_BRANCH" 2>/dev/null

echo ""
echo "Step 3: CI will run and fail on TestRetryBackoffZero"
echo "Step 4: GitHub webhook fires to agent-blueprints-demo worker"
echo "Step 5: Agent investigates via Sourcegraph Deep Search + MCP"
echo "Step 6: Agent posts root-cause analysis comment on commit"
echo ""
echo "Expected timeline: 20-40 seconds"
echo ""
echo "Monitor at: https://github.com/sg-evals/agent-blueprints-demo-monorepo/actions"
echo ""

# Wait for completion (poll for commit comment)
COMMIT_SHA=$(git rev-parse HEAD)
echo "Watching commit ${COMMIT_SHA:0:8} for investigation comment..."

for i in $(seq 1 60); do
  COMMENTS=$(gh api "repos/sg-evals/agent-blueprints-demo-monorepo/commits/$COMMIT_SHA/comments" --jq 'length' 2>/dev/null || echo "0")
  if [ "$COMMENTS" -gt 0 ]; then
    echo ""
    echo "Investigation comment posted!"
    echo ""
    gh api "repos/sg-evals/agent-blueprints-demo-monorepo/commits/$COMMIT_SHA/comments" --jq '.[0].body' 2>/dev/null
    break
  fi
  printf "."
  sleep 2
done

echo ""
echo "Demo complete."
