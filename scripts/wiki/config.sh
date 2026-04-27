#!/bin/bash
# Shared config for wiki tooling.
# Sourced by other scripts: source "$(dirname "$0")/config.sh"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
WIKI_DIR="$PROJECT_DIR/wiki"
DAILY_DIR="$WIKI_DIR/daily"
KNOWLEDGE_DIR="$WIKI_DIR/knowledge"
CONCEPTS_DIR="$KNOWLEDGE_DIR/concepts"
CONNECTIONS_DIR="$KNOWLEDGE_DIR/connections"
QA_DIR="$KNOWLEDGE_DIR/qa"
LESSONS_DIR="$WIKI_DIR/lessons"
BUILDS_DIR="$WIKI_DIR/builds"
USER_DIR="$WIKI_DIR/user"
STATUS_FILE="$WIKI_DIR/STATUS.md"
INDEX_FILE="$WIKI_DIR/index.md"
LOG_FILE="$WIKI_DIR/log.md"
AGENTS_FILE="$WIKI_DIR/AGENTS.md"
STATE_FILE="$PROJECT_DIR/scripts/wiki/state.json"
FLUSH_STATE="$PROJECT_DIR/scripts/wiki/last-flush.json"

# Local TZ
TZ_NAME="Europe/Moscow"

now_iso() { date "+%Y-%m-%dT%H:%M:%S%:z"; }
today_iso() { date "+%Y-%m-%d"; }

# Ensure JSON state file exists
ensure_state() {
  if [ ! -f "$STATE_FILE" ]; then
    mkdir -p "$(dirname "$STATE_FILE")"
    echo '{"ingested":{},"query_count":0,"last_lint":null,"total_cost":0.0,"last_compile":null}' > "$STATE_FILE"
  fi
}

log_to_wiki_log() {
  local action="$1"; local detail="$2"
  [ -f "$LOG_FILE" ] || echo "# Wiki Log" > "$LOG_FILE"
  echo "- $(now_iso) $action — $detail" >> "$LOG_FILE"
}
