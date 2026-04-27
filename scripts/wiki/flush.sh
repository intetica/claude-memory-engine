#!/bin/bash
# wiki flush — LLM extraction from session transcript into daily log.
# Spawned in background by session-end-wiki.sh or pre-compact-wiki.sh.
#
# Usage: bash scripts/wiki/flush.sh <context_file.md> <session_id>

set -uo pipefail

# Recursion guard — skip if invoked from within another Claude session.
if [ -n "${CLAUDE_INVOKED_BY:-}" ]; then
  exit 0
fi
export CLAUDE_INVOKED_BY="wiki_flush"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

CONTEXT_FILE="${1:-}"
SESSION_ID="${2:-unknown}"
LOG_FILE_FLUSH="$SCRIPT_DIR/flush.log"

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE_FLUSH"; }

log "flush.sh started for session=$SESSION_ID context=$CONTEXT_FILE"

if [ -z "$CONTEXT_FILE" ] || [ ! -f "$CONTEXT_FILE" ]; then
  log "ERROR: context file missing: $CONTEXT_FILE"
  exit 1
fi

# Dedup: skip if same session within 60s
if [ -f "$FLUSH_STATE" ] && command -v jq >/dev/null 2>&1; then
  prev_sid=$(jq -r '.session_id // ""' "$FLUSH_STATE")
  prev_ts=$(jq -r '.timestamp // 0' "$FLUSH_STATE")
  now_ts=$(date +%s)
  if [ "$prev_sid" = "$SESSION_ID" ] && [ $((now_ts - prev_ts)) -lt 60 ]; then
    log "dedup: same session within 60s, skip"
    rm -f "$CONTEXT_FILE"
    exit 0
  fi
fi

CONTEXT=$(cat "$CONTEXT_FILE")
if [ -z "$CONTEXT" ]; then
  log "empty context, skip"
  rm -f "$CONTEXT_FILE"
  exit 0
fi

PROMPT="Review the conversation context below and respond with a concise summary of important items that should be preserved in the daily log. Do NOT use any tools — just return plain text.

Format your response as a structured daily log entry with these sections:

**Context:** [One line about what the user was working on]

**Key Exchanges:**
- [Important Q&A or discussions]

**Decisions Made:**
- [Any decisions with rationale]

**Lessons Learned:**
- [Gotchas, patterns, or insights discovered]

**Action Items:**
- [Follow-ups or TODOs mentioned]

Skip anything that is:
- Routine tool calls or file reads
- Content that's trivial or obvious
- Trivial back-and-forth or clarification exchanges

Only include sections that have actual content. If nothing is worth saving, respond with exactly: FLUSH_OK

After the markdown summary, ALWAYS append a structured XML block (no markdown wrapping) for database persistence:

<summary>
  <request>What the user asked for in 1 sentence (max 500 chars)</request>
  <investigated>What was checked/explored (max 1000 chars). Empty if none.</investigated>
  <learned>Key insights or surprises (max 1000 chars). Empty if none.</learned>
  <completed>What was actually done/changed (max 1000 chars). Empty if none.</completed>
  <next_steps>Pending follow-ups (max 500 chars). Empty if none.</next_steps>
  <notes>Other notable items (max 500 chars). Empty if none.</notes>
</summary>

If FLUSH_OK, still return the XML block with mostly-empty fields and request='nothing significant to save'.

## Conversation Context

${CONTEXT}"

RESPONSE=$(echo "$PROMPT" | claude -p 2>&1)
RC=$?
log "claude exit=$RC response_length=${#RESPONSE}"

# Append to today's daily log
mkdir -p "$DAILY_DIR"
TODAY=$(today_iso)
DAILY_FILE="$DAILY_DIR/$TODAY.md"

if [ ! -f "$DAILY_FILE" ]; then
  cat > "$DAILY_FILE" <<EOF
# Daily Log: $TODAY

## Sessions

## Memory Maintenance

EOF
fi

TIME=$(date "+%H:%M")
# Strip XML <summary> block from markdown saved to daily log (keep XML for DB only)
RESPONSE_MD=$(printf '%s' "$RESPONSE" | sed '/<summary>/,/<\/summary>/d')
RESPONSE_XML=$(printf '%s' "$RESPONSE" | awk '/<summary>/,/<\/summary>/' | head -100)

if echo "$RESPONSE_MD" | grep -q "^FLUSH_OK$"; then
  log "FLUSH_OK — nothing to save"
  echo -e "\n### Memory Flush ($TIME)\n\nFLUSH_OK — nothing worth saving from this session ($SESSION_ID)\n" >> "$DAILY_FILE"
else
  echo -e "\n### Session ($TIME, $SESSION_ID)\n\n$RESPONSE_MD\n" >> "$DAILY_FILE"
  log "appended to $DAILY_FILE"
fi

# Parallel write summary to DB (best-effort, never block markdown flow)
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ENV_FILE="$PROJECT_DIR/.env.local"
if [ -n "$RESPONSE_XML" ] && [ -f "$ENV_FILE" ] && command -v xmllint >/dev/null 2>&1; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  if [ -n "${DATABASE_URL:-}" ] && command -v psql >/dev/null 2>&1; then
    extract_field() {
      printf '%s' "$RESPONSE_XML" | xmllint --xpath "string(/summary/$1)" - 2>/dev/null | head -c "$2"
    }
    XML_REQUEST=$(extract_field request 500)
    XML_INVESTIGATED=$(extract_field investigated 1000)
    XML_LEARNED=$(extract_field learned 1000)
    XML_COMPLETED=$(extract_field completed 1000)
    XML_NEXT_STEPS=$(extract_field next_steps 500)
    XML_NOTES=$(extract_field notes 500)

    # Coerce: if all 6 fields empty → maybe LLM returned <observation>; use markdown summary as notes
    if [ -z "$XML_REQUEST$XML_INVESTIGATED$XML_LEARNED$XML_COMPLETED$XML_NEXT_STEPS$XML_NOTES" ]; then
      XML_REQUEST="(no XML — coerced from markdown)"
      XML_NOTES=$(printf '%s' "$RESPONSE_MD" | head -c 500)
      log "summary XML missing — coerced from markdown"
    fi

    # Escape single quotes for PG single-quoted literal: ' → ''
    sq_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
    SID_E=$(sq_escape "$SESSION_ID")
    REQ_E=$(sq_escape "$XML_REQUEST")
    INV_E=$(sq_escape "$XML_INVESTIGATED")
    LRN_E=$(sq_escape "$XML_LEARNED")
    COM_E=$(sq_escape "$XML_COMPLETED")
    NXT_E=$(sq_escape "$XML_NEXT_STEPS")
    NTS_E=$(sq_escape "$XML_NOTES")

    psql_result=$(psql "$DATABASE_URL" -tA -v ON_ERROR_STOP=1 <<SQL 2>&1
INSERT INTO ${MEMORY_SCHEMA:-claude_memory}.summaries (session_id, project, request, investigated, learned, completed, next_steps, notes)
VALUES ('$SID_E', "${MEMORY_PROJECT:-default}", NULLIF('$REQ_E',''), NULLIF('$INV_E',''), NULLIF('$LRN_E',''), NULLIF('$COM_E',''), NULLIF('$NXT_E',''), NULLIF('$NTS_E',''))
ON CONFLICT (session_id) DO UPDATE SET
  request = EXCLUDED.request,
  investigated = EXCLUDED.investigated,
  learned = EXCLUDED.learned,
  completed = EXCLUDED.completed,
  next_steps = EXCLUDED.next_steps,
  notes = EXCLUDED.notes
RETURNING id;
SQL
)
    if echo "$psql_result" | grep -qE '^[0-9]+$'; then
      log "summary inserted to DB id=$psql_result"
    else
      log "summary DB insert failed: $(echo "$psql_result" | head -1)"
    fi
  fi
fi

# Update dedup state
if command -v jq >/dev/null 2>&1; then
  echo "{\"session_id\":\"$SESSION_ID\",\"timestamp\":$(date +%s)}" > "$FLUSH_STATE"
fi

log_to_wiki_log "flush" "session=$SESSION_ID length=${#RESPONSE}"
rm -f "$CONTEXT_FILE"

# After 18:00 local, optionally trigger compile if today's log changed
HOUR=$(date "+%H")
if [ "$HOUR" -ge 18 ] && [ -x "$SCRIPT_DIR/compile.sh" ]; then
  log "post-18:00 auto-trigger compile.sh"
  nohup bash "$SCRIPT_DIR/compile.sh" --file "$DAILY_FILE" > "$SCRIPT_DIR/compile.log" 2>&1 &
  disown 2>/dev/null || true
fi

log "flush done for session=$SESSION_ID"
exit 0
