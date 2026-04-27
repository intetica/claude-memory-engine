#!/bin/bash
# SessionStart hook: inject wiki/STATUS.md + memory recall into session context.
# Max additionalContext: ~10_000 chars (Claude Code limit).

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
STATUS_FILE="$PROJECT_DIR/wiki/STATUS.md"

# Freshness gate: regen STATUS if older than HEAD by >5 min.
if [ -f "$STATUS_FILE" ]; then
  STATUS_MTIME=$(stat -c %Y "$STATUS_FILE" 2>/dev/null || stat -f %m "$STATUS_FILE" 2>/dev/null || echo 0)
  HEAD_TIME=$(cd "$PROJECT_DIR" && git log -1 --format=%ct 2>/dev/null || echo 0)
  DIFF=$((HEAD_TIME - STATUS_MTIME))
  if [ "$DIFF" -gt 300 ]; then
    bash "$PROJECT_DIR/scripts/wiki/update-status.sh" >/dev/null 2>&1 || true
  fi
fi

# Read STATUS (or fallback).
if [ -f "$STATUS_FILE" ]; then
  STATUS=$(cat "$STATUS_FILE")
else
  STATUS="(wiki/STATUS.md not found — run scripts/wiki/update-status.sh)"
fi

# Memory recall: top-5 observations by active topic name.
MEMORY_RECALL=""
ACTIVE_BUILD=$(grep -oP '\*\*Active Build:\*\*\s*\K[^\s]+' "$STATUS_FILE" 2>/dev/null | head -1)
if [ -z "$ACTIVE_BUILD" ]; then
  ACTIVE_BUILD=$(ls -d "$PROJECT_DIR"/docs/build/*/ 2>/dev/null | tail -1 | xargs -r basename 2>/dev/null)
fi
if [ -n "$ACTIVE_BUILD" ]; then
  TOPIC="${ACTIVE_BUILD#????-??-??_}"
  RECALL_RAW=$(timeout 10 bash "$PROJECT_DIR/scripts/wiki/query.sh" "$TOPIC" 2>/dev/null | head -25)
  if [ -n "$RECALL_RAW" ]; then
    SERVER_NAME="${MEMORY_SERVER_NAME:-claude-memory}"
    MEMORY_RECALL="## Memory recall: $TOPIC

$RECALL_RAW

(Auto-pulled by SessionStart hook. For full text — mcp__${SERVER_NAME}__get_details with id.)

---

"
  fi
fi

# Compose context (max ~9500 chars to leave margin for JSON escaping).
CONTEXT="---

# Project Status

${STATUS}

---

${MEMORY_RECALL}**Full context:** wiki/index.md · .claude/rules/ (auto-loaded)"

CONTEXT="${CONTEXT:0:9500}"

# JSON-escape via jq when available.
if command -v jq >/dev/null 2>&1; then
  JSON=$(jq -n \
    --arg ctx "$CONTEXT" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}')
else
  ESCAPED=$(printf '%s' "$CONTEXT" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}')
  JSON="{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"${ESCAPED}\"}}"
fi

echo "$JSON"
