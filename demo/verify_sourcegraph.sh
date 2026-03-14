#!/bin/bash
# Verify Sourcegraph MCP integration works against the real API.
# This script makes real API calls to sourcegraph.sourcegraph.com.
#
# Prerequisites:
#   export SOURCEGRAPH_ACCESS_TOKEN="sgp_..."
#
# Usage:
#   ./demo/verify_sourcegraph.sh [repo]
set -euo pipefail

MCP_ENDPOINT="https://sourcegraph.sourcegraph.com/.api/mcp/v1"
REPO="${1:-github.com/sg-evals/agent-blueprints-demo-monorepo}"

if [ -z "${SOURCEGRAPH_ACCESS_TOKEN:-}" ]; then
  echo "ERROR: SOURCEGRAPH_ACCESS_TOKEN not set"
  echo "  export SOURCEGRAPH_ACCESS_TOKEN='sgp_...'"
  exit 1
fi

PASS=0
FAIL=0

call_mcp() {
  local tool="$1"
  local args="$2"
  local desc="$3"

  echo -n "  $desc... "

  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "$MCP_ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "Authorization: token $SOURCEGRAPH_ACCESS_TOKEN" \
    -d "{
      \"jsonrpc\": \"2.0\",
      \"method\": \"tools/call\",
      \"params\": {
        \"name\": \"$tool\",
        \"arguments\": $args
      },
      \"id\": \"verify-$(date +%s)-$RANDOM\"
    }")

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | head -n -1)

  if [ "$HTTP_CODE" = "200" ]; then
    # Check for MCP-level errors
    ERROR=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',{}).get('message',''))" 2>/dev/null || echo "")
    if [ -n "$ERROR" ]; then
      echo "FAIL (MCP error: $ERROR)"
      FAIL=$((FAIL + 1))
    else
      CONTENT=$(echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
texts = [c['text'] for c in d.get('result',{}).get('content',[]) if c.get('type')=='text']
print(texts[0][:200] if texts else '(no text content)')
" 2>/dev/null || echo "(parse error)")
      echo "OK"
      echo "    → ${CONTENT}"
      PASS=$((PASS + 1))
    fi
  else
    echo "FAIL (HTTP $HTTP_CODE)"
    FAIL=$((FAIL + 1))
  fi
  echo ""
}

echo "=== Sourcegraph MCP Integration Verification ==="
echo "Endpoint: $MCP_ENDPOINT"
echo "Repo: $REPO"
echo ""

echo "[1/5] Keyword Search: RetryBackoff"
call_mcp "sg_keyword_search" \
  "{\"query\": \"RetryBackoff\", \"repo\": \"$REPO\"}" \
  "Searching for RetryBackoff symbol"

echo "[2/5] Read File: libs/retry/backoff.go"
call_mcp "sg_read_file" \
  "{\"repo\": \"$REPO\", \"path\": \"libs/retry/backoff.go\"}" \
  "Reading backoff.go source"

echo "[3/5] List Files: libs/retry"
call_mcp "sg_list_files" \
  "{\"repo\": \"$REPO\", \"path\": \"libs/retry\"}" \
  "Listing files in libs/retry"

echo "[4/5] Semantic Search: negative backoff delay"
call_mcp "sg_nls_search" \
  "{\"query\": \"function that calculates retry backoff delay\", \"repo\": \"$REPO\"}" \
  "Semantic search for backoff logic"

echo "[5/5] Deep Search: investigate retry failure"
call_mcp "sg_deepsearch" \
  "{\"query\": \"Investigate why RetryBackoff returns negative duration when attempt is 0\", \"repo\": \"$REPO\"}" \
  "Deep Search investigation (may take 10-30s)"

echo "=== Results ==="
echo "Passed: $PASS / $((PASS + FAIL))"
echo "Failed: $FAIL / $((PASS + FAIL))"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Some tests failed. Ensure the repo is indexed on Sourcegraph."
  exit 1
fi

echo ""
echo "All Sourcegraph integrations verified!"
