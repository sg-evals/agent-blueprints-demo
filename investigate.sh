#!/bin/bash
# Launch a Claude Code agent to investigate a CI test failure.
#
# Usage:
#   ./investigate.sh --repo <owner/repo> --test <test_name> --error <error_msg> [--sha <commit>] [--post-comment]
#
# Prerequisites:
#   SOURCEGRAPH_ACCESS_TOKEN - for MCP tools
#   ANTHROPIC_API_KEY        - for Claude Code
#   GITHUB_TOKEN             - for posting comments (optional)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse args
REPO=""
TEST_NAME=""
ERROR_MSG=""
COMMIT_SHA=""
POST_COMMENT=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --repo)       REPO="$2"; shift 2 ;;
    --test)       TEST_NAME="$2"; shift 2 ;;
    --error)      ERROR_MSG="$2"; shift 2 ;;
    --sha)        COMMIT_SHA="$2"; shift 2 ;;
    --post-comment) POST_COMMENT=true; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [ -z "$REPO" ] || [ -z "$TEST_NAME" ]; then
  echo "Usage: ./investigate.sh --repo <owner/repo> --test <test_name> --error <error_msg>"
  exit 1
fi

SG_REPO="github.com/$REPO"

# Verify prerequisites
if [ -z "${SOURCEGRAPH_ACCESS_TOKEN:-}" ]; then
  echo "ERROR: SOURCEGRAPH_ACCESS_TOKEN not set"
  exit 1
fi

if ! command -v claude &> /dev/null; then
  echo "ERROR: claude CLI not found. Install Claude Code first."
  exit 1
fi

# Build the investigation prompt
PROMPT="Investigate this CI test failure using the Sourcegraph MCP tools.

Repository: $SG_REPO
Failing test: $TEST_NAME
Error message: $ERROR_MSG

Instructions:
1. Use mcp__sourcegraph__sg_keyword_search to find the test '$TEST_NAME' in the repo '$SG_REPO'
2. Use mcp__sourcegraph__sg_read_file to read the test file and understand what it tests
3. Use mcp__sourcegraph__sg_go_to_definition or sg_keyword_search to find the function being tested
4. Use mcp__sourcegraph__sg_read_file to read the implementation
5. Use mcp__sourcegraph__sg_commit_search to find recent changes to the implementation
6. Identify the root cause and write your findings to investigation_output.md

The output file must follow the format specified in CLAUDE.md."

echo "=== CI Failure Investigation ==="
echo "Repo:  $REPO"
echo "Test:  $TEST_NAME"
echo "Error: $ERROR_MSG"
echo ""
echo "Launching Claude Code agent with Sourcegraph MCP..."
echo ""

# Set up allowed tools
MCP_TOOLS="mcp__sourcegraph__sg_keyword_search"
MCP_TOOLS="$MCP_TOOLS,mcp__sourcegraph__sg_nls_search"
MCP_TOOLS="$MCP_TOOLS,mcp__sourcegraph__sg_read_file"
MCP_TOOLS="$MCP_TOOLS,mcp__sourcegraph__sg_list_files"
MCP_TOOLS="$MCP_TOOLS,mcp__sourcegraph__sg_go_to_definition"
MCP_TOOLS="$MCP_TOOLS,mcp__sourcegraph__sg_find_references"
MCP_TOOLS="$MCP_TOOLS,mcp__sourcegraph__sg_commit_search"
ALLOWED_TOOLS="Read,Write,Grep,Glob,$MCP_TOOLS"

# Run Claude Code agent
cd "$SCRIPT_DIR"
claude --print \
  --allowedTools "$ALLOWED_TOOLS" \
  --prompt "$PROMPT"

# Check if output was generated
if [ ! -f "$SCRIPT_DIR/investigation_output.md" ]; then
  echo ""
  echo "WARNING: investigation_output.md was not created"
  exit 1
fi

echo ""
echo "=== Investigation Complete ==="
echo ""
cat "$SCRIPT_DIR/investigation_output.md"

# Post as GitHub comment if requested
if [ "$POST_COMMENT" = true ] && [ -n "$COMMIT_SHA" ]; then
  echo ""
  echo "Posting comment on $REPO@${COMMIT_SHA:0:8}..."
  BODY=$(cat "$SCRIPT_DIR/investigation_output.md")
  gh api "repos/$REPO/commits/$COMMIT_SHA/comments" \
    -f body="$BODY" \
    --silent
  echo "Comment posted."
fi
