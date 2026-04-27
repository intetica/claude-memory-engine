#!/bin/bash
# Memory Engine — PostToolUse capture hook
# Source: Design D32
# Critical: завершаемся <30мс. Никаких LLM, никакой блокировки.

set -uo pipefail

# Recursion guard
if [ -n "${CLAUDE_INVOKED_BY:-}" ]; then
  exit 0
fi

INPUT=$(cat)

# Filter: только важные tool uses
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
case "$TOOL" in
  Edit|Write) ;;
  Bash)
    # Только важные bash: git commit, migration, supabase, psql
    if ! echo "$INPUT" | jq -e '.tool_input.command | test("git commit|migration|supabase|psql|npm run wiki:")' >/dev/null 2>&1; then
      exit 0
    fi
    ;;
  *) exit 0 ;;
esac

# Determine project dir
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
QUEUE_DIR="$PROJECT_DIR/wiki/queue"
mkdir -p "$QUEUE_DIR"

# Atomic write: nanoseconds + content hash + PID для уникальности
TS_NS=$(date +%s%N | cut -c1-16)
HASH=$(echo "$INPUT" | sha256sum | cut -c1-24)
TMP="$QUEUE_DIR/.${TS_NS}-${HASH}-$$.tmp"
DST="$QUEUE_DIR/${TS_NS}-${HASH}-$$.json"

echo "$INPUT" > "$TMP"
mv "$TMP" "$DST"

exit 0
