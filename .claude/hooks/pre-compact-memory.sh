#!/bin/bash
# PreCompact hook — same as SessionEnd but fires before context compaction.
# Ported from coleam00/claude-memory-compiler hooks/pre-compact.py

set -uo pipefail

if [ -n "${CLAUDE_INVOKED_BY:-}" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SCRIPT_DIR="$PROJECT_DIR/scripts/wiki"

HOOK_INPUT=$(cat 2>/dev/null || echo "{}")

if command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // "unknown"')
  TRANSCRIPT=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // ""')
else
  SESSION_ID=$(echo "$HOOK_INPUT" | grep -oP '"session_id":\s*"\K[^"]+' | head -1)
  TRANSCRIPT=$(echo "$HOOK_INPUT" | grep -oP '"transcript_path":\s*"\K[^"]+' | head -1)
  SESSION_ID="${SESSION_ID:-unknown}"
fi

# PreCompact: higher MIN_TURNS threshold to avoid trivial mid-session compacts
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  exit 0
fi

CONTEXT_FILE="$SCRIPT_DIR/flush-context-${SESSION_ID}-$(date +%s).md"
mkdir -p "$SCRIPT_DIR"

if command -v jq >/dev/null 2>&1; then
  {
    tail -100 "$TRANSCRIPT" | while IFS= read -r line; do
      echo "$line" | jq -r '
        .message // . |
        select(.role == "user" or .role == "assistant") |
        .content as $c |
        if ($c | type) == "string" then "**\(.role):** \($c)"
        elif ($c | type) == "array" then
          ($c | map(select(.type == "text") | .text) | join("\n")) as $txt |
          if $txt == "" then empty else "**\(.role):** \($txt)" end
        else empty end
      ' 2>/dev/null
    done
  } > "$CONTEXT_FILE"

  SIZE=$(wc -c < "$CONTEXT_FILE" 2>/dev/null || echo 0)
  if [ "$SIZE" -gt 15000 ]; then
    tail -c 15000 "$CONTEXT_FILE" > "${CONTEXT_FILE}.tmp" && mv "${CONTEXT_FILE}.tmp" "$CONTEXT_FILE"
  fi

  # Skip if less than 5 turns of content (pre-compact threshold)
  TURN_COUNT=$(grep -c "^\*\*\(user\|assistant\):\*\*" "$CONTEXT_FILE" 2>/dev/null || echo 0)
  if [ "$TURN_COUNT" -lt 5 ]; then
    rm -f "$CONTEXT_FILE"
    exit 0
  fi
fi

if [ ! -s "$CONTEXT_FILE" ]; then
  rm -f "$CONTEXT_FILE"
  exit 0
fi

if [ -x "$SCRIPT_DIR/flush.sh" ]; then
  nohup bash "$SCRIPT_DIR/flush.sh" "$CONTEXT_FILE" "$SESSION_ID" > "$SCRIPT_DIR/flush.log" 2>&1 &
  disown 2>/dev/null || true
fi

exit 0
