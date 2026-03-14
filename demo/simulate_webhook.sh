#!/bin/bash
# Simulate a GitHub webhook locally for testing the worker.
set -euo pipefail

WORKER_URL="${WORKER_URL:-http://localhost:8787}"

echo "=== Simulating GitHub Webhook ==="

PAYLOAD=$(cat <<'PAYLOAD_EOF'
{
  "action": "completed",
  "workflow_run": {
    "id": 12345678,
    "name": "CI Fast",
    "head_sha": "abc123def456",
    "head_branch": "demo/ci-failure-001",
    "conclusion": "failure",
    "html_url": "https://github.com/sg-evals/agent-blueprints-demo-monorepo/actions/runs/12345678",
    "repository": {
      "full_name": "sg-evals/agent-blueprints-demo-monorepo"
    }
  }
}
PAYLOAD_EOF
)

echo "Sending webhook to $WORKER_URL/webhook/github..."
echo ""

RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST "$WORKER_URL/webhook/github" \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: workflow_run" \
  -H "X-Hub-Signature-256: sha256=test" \
  -d "$PAYLOAD")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

echo "Status: $HTTP_CODE"
echo "Response: $BODY"

if [ "$HTTP_CODE" = "200" ]; then
  echo ""
  echo "Webhook accepted! Job enqueued for investigation."
else
  echo ""
  echo "Webhook rejected (status $HTTP_CODE)."
fi
