#!/bin/bash
# Memory Engine — One-shot migration of memory/*.md → ${MEMORY_SCHEMA:-claude_memory}.observations
# Source: Design D31
# Modes: --dry-run (preview) | --commit (real INSERT)
# Classify by filename: feedback_* → decision, project_* → discovery, user_* → discovery, default → change

set -uo pipefail

if [ -n "${CLAUDE_INVOKED_BY:-}" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Auto-detect Claude Code memory directory for the current project.
# Pattern used by Claude Code: ~/.claude/projects/<encoded-cwd>/memory
ENCODED_PWD=$(echo "-${PROJECT_DIR}" | sed 's|/|-|g')
MEMORY_DIR="${MEMORY_SOURCE_DIR:-${HOME}/.claude/projects/${ENCODED_PWD}/memory}"
LOG_FILE="$PROJECT_DIR/scripts/wiki/migrate-memory.log"

MODE="dry-run"
for arg in "$@"; do
  case "$arg" in
    --commit) MODE="commit" ;;
    --dry-run) MODE="dry-run" ;;
  esac
done

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

if [ ! -d "$MEMORY_DIR" ]; then
  log "ERROR: memory dir not found: $MEMORY_DIR"
  exit 1
fi

# Classify by filename
classify() {
  local fname="$1"
  case "$fname" in
    feedback_*) echo "decision" ;;
    project_*)  echo "discovery" ;;
    user_*)     echo "discovery" ;;
    *)          echo "change" ;;
  esac
}

# Extract title from first '# Header' line in file
extract_title() {
  local file="$1"
  grep -m1 '^# ' "$file" 2>/dev/null | sed 's/^# //' || echo ""
}

# Compute SHA256[:24] of session+title+narrative
compute_hash() {
  local session="$1"
  local title="$2"
  local narrative="$3"
  echo -n "$session $title $narrative" | sha256sum | cut -c1-24
}

# JSON-escape a string for psql
json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$1"
}

if [ "$MODE" = "commit" ]; then
  # Backup ДО миграции
  BACKUP_DIR="memory.backup-$(date '+%Y%m%d-%H%M%S')"
  log "backup: $MEMORY_DIR → $PROJECT_DIR/$BACKUP_DIR"
  cp -r "$MEMORY_DIR" "$PROJECT_DIR/$BACKUP_DIR"
fi

TOTAL=0
MIGRATED=0
SKIPPED=0
FAILED=0

log "=== Memory migration started (mode=$MODE) ==="
log "Source: $MEMORY_DIR"

# Iterate over .md files
for file in "$MEMORY_DIR"/*.md; do
  [ -f "$file" ] || continue
  fname=$(basename "$file")
  # Skip MEMORY.md (index)
  if [ "$fname" = "MEMORY.md" ]; then
    continue
  fi
  TOTAL=$((TOTAL + 1))

  type=$(classify "$fname")
  title=$(extract_title "$file")
  if [ -z "$title" ]; then
    title=$(echo "$fname" | sed 's/\.md$//' | tr '_' ' ')
  fi
  # Truncate title to <120 chars
  title="${title:0:120}"

  # Narrative = full file content (after frontmatter)
  narrative=$(awk '/^---$/{c++;next} c<2{next} {print}' "$file" 2>/dev/null || cat "$file")
  if [ -z "$narrative" ] || [ ${#narrative} -lt 11 ]; then
    narrative=$(cat "$file")
  fi
  # Truncate narrative to 4500 chars (safe under 5000)
  narrative="${narrative:0:4500}"

  session_id="memory-migration-${fname%.md}"
  content_hash=$(compute_hash "$session_id" "$title" "$narrative")

  if [ "$MODE" = "dry-run" ]; then
    echo "  $fname → type=$type, title=\"${title:0:60}\", hash=$content_hash"
    MIGRATED=$((MIGRATED + 1))
  else
    # Real INSERT via Supabase REST API (psql wrapper)
    title_json=$(json_escape "$title")
    narrative_json=$(json_escape "$narrative")
    files_modified="[\"$file\"]"

    payload=$(cat << JSON
{
  "project": "${MEMORY_PROJECT:-default}",
  "session_id": "$session_id",
  "type": "$type",
  "title": $title_json,
  "narrative": $narrative_json,
  "facts": [],
  "concepts": [],
  "files_read": [],
  "files_modified": $files_modified,
  "content_hash": "$content_hash"
}
JSON
)
    if [ -z "${DATABASE_URL:-}" ]; then
      log "ERROR: DATABASE_URL missing"
      exit 1
    fi
    # Build SQL INSERT — use psql variable binding for safety
    title_sql=$(printf '%s' "$title" | sed "s/'/''/g")
    narrative_sql=$(printf '%s' "$narrative" | sed "s/'/''/g")
    sql="INSERT INTO ${MEMORY_SCHEMA:-claude_memory}.observations (project, session_id, type, title, narrative, content_hash, files_modified) VALUES ('${MEMORY_PROJECT:-default}', '$session_id', '$type', '$title_sql', '$narrative_sql', '$content_hash', ARRAY['$file']::text[]) ON CONFLICT (content_hash, project, (created_at_epoch / 60000)) DO NOTHING RETURNING id;"
    result=$(psql "$DATABASE_URL" -tA -c "$sql" 2>&1)
    if echo "$result" | grep -qE '^[0-9]+$'; then
      MIGRATED=$((MIGRATED + 1))
      log "migrated: $fname (type=$type, id=$result)"
    elif echo "$result" | grep -q "INSERT 0 0"; then
      SKIPPED=$((SKIPPED + 1))
      log "dedup: $fname"
    elif [ -z "$result" ]; then
      SKIPPED=$((SKIPPED + 1))
      log "dedup (empty result): $fname"
    else
      FAILED=$((FAILED + 1))
      log "failed: $fname error=$(echo "$result" | head -1)"
    fi
  fi
done

log "=== Summary ==="
log "Total: $TOTAL files"
log "Migrated: $MIGRATED"
log "Dedup skipped: $SKIPPED"
log "Failed: $FAILED"

if [ "$MODE" = "dry-run" ]; then
  log ""
  log "This was a DRY RUN. Run with --commit to actually insert."
fi
