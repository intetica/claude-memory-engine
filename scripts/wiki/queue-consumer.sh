#!/bin/bash
# Memory Engine — Queue consumer with claim-confirm + self-healing
# Source: Design D28
# Reads wiki/queue/*.json, calls extractor.ts, INSERTs observations.
# Self-healing: stale processing >60s → reset.
# Retry: max 3 attempts, then move to .deadletter/

set -uo pipefail

if [ -n "${CLAUDE_INVOKED_BY:-}" ]; then
  exit 0
fi
export CLAUDE_INVOKED_BY="wiki_queue_consumer"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
QUEUE_DIR="$PROJECT_DIR/wiki/queue"
PROCESSING_DIR="$QUEUE_DIR/.processing"
DEADLETTER_DIR="$QUEUE_DIR/.deadletter"
LOG_FILE="$PROJECT_DIR/scripts/wiki/queue-consumer.log"

# Load .env.local (consumer runs via nohup → no inherited shell env)
ENV_FILE="$PROJECT_DIR/.env.local"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

# Universal env mapping (extractor handles ANTHROPIC vs OPENROUTER selection itself)
export SUPABASE_URL="${SUPABASE_URL:-${NEXT_PUBLIC_SUPABASE_URL:-}}"

mkdir -p "$QUEUE_DIR" "$PROCESSING_DIR" "$DEADLETTER_DIR"

ONCE_MODE=false
POLL_INTERVAL=10
STALE_TIMEOUT=60
MAX_RETRIES=3

for arg in "$@"; do
  case "$arg" in
    --once) ONCE_MODE=true ;;
    --interval=*) POLL_INTERVAL="${arg#*=}" ;;
  esac
done

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Self-heal: reset stale processing files older than STALE_TIMEOUT seconds
self_heal() {
  local now
  now=$(date +%s)
  for f in "$PROCESSING_DIR"/*.json; do
    [ -f "$f" ] || continue
    local mtime
    mtime=$(stat -c %Y "$f" 2>/dev/null || echo "$now")
    local age=$((now - mtime))
    if [ "$age" -gt "$STALE_TIMEOUT" ]; then
      local fname
      fname=$(basename "$f")
      log "self-heal: reset stale $fname (age ${age}s)"
      mv "$f" "$QUEUE_DIR/$fname" 2>/dev/null || true
    fi
  done
}

# Process one event file
process_event() {
  local src="$1"
  local fname
  fname=$(basename "$src")
  local proc="$PROCESSING_DIR/$fname"

  # Atomic claim
  if ! mv "$src" "$proc" 2>/dev/null; then
    return 0  # someone else got it
  fi

  log "claim: $fname"

  # Read retry_count
  local retry_count
  retry_count=$(jq -r '.retry_count // 0' "$proc" 2>/dev/null || echo 0)

  # Run extractor (use local tsx from node_modules to avoid PATH issues under nohup)
  local TSX_BIN="$PROJECT_DIR/node_modules/.bin/tsx"
  if [ ! -x "$TSX_BIN" ]; then
    TSX_BIN="tsx" # fallback to PATH
  fi
  local result
  if ! result=$("$TSX_BIN" "$SCRIPT_DIR/queue-consumer/extractor.ts" < "$proc" 2>>"$LOG_FILE"); then
    # Failed
    retry_count=$((retry_count + 1))
    if [ "$retry_count" -ge "$MAX_RETRIES" ]; then
      log "deadletter: $fname (retries=$retry_count)"
      mv "$proc" "$DEADLETTER_DIR/$fname"
    else
      log "retry: $fname (retry_count=$retry_count)"
      jq --arg rc "$retry_count" '.retry_count = ($rc | tonumber)' "$proc" > "${proc}.tmp" 2>/dev/null \
        && mv "${proc}.tmp" "$QUEUE_DIR/$fname" \
        || mv "$proc" "$QUEUE_DIR/$fname"
    fi
    return 1
  fi

  # Success — log result
  local status
  status=$(echo "$result" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
  local obs_id
  obs_id=$(echo "$result" | jq -r '.observation_id // "null"' 2>/dev/null || echo "null")
  log "processed: $fname status=$status observation_id=$obs_id"

  # Confirm: delete file
  rm -f "$proc"
  return 0
}

# Main loop
while true; do
  self_heal

  # Process all events in queue
  local_count=0
  for f in "$QUEUE_DIR"/*.json; do
    [ -f "$f" ] || continue
    process_event "$f"
    local_count=$((local_count + 1))
  done

  if [ "$ONCE_MODE" = true ]; then
    log "once mode complete (processed $local_count events)"
    exit 0
  fi

  sleep "$POLL_INTERVAL"
done
