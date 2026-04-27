#!/bin/bash
# wiki compile — LLM synthesis: daily logs → knowledge articles.
# Ports scripts/compile.py from coleam00/claude-memory-compiler.
#
# Usage:
#   bash scripts/wiki/compile.sh                    # compile new/changed logs
#   bash scripts/wiki/compile.sh --all              # force recompile everything
#   bash scripts/wiki/compile.sh --file <path>      # compile specific file
#   bash scripts/wiki/compile.sh --dry-run          # show what would be compiled

set -uo pipefail

if [ -n "${CLAUDE_INVOKED_BY:-}" ]; then
  exit 0
fi
export CLAUDE_INVOKED_BY="wiki_compile"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"
ensure_state

MODE="incremental"
TARGET_FILE=""
DRY=false
for arg in "$@"; do
  case "$arg" in
    --all) MODE="all" ;;
    --dry-run) DRY=true ;;
    --file) : ;;
    *) [ -z "$TARGET_FILE" ] && [[ "$arg" == *.md ]] && TARGET_FILE="$arg" ;;
  esac
done

file_hash() { sha256sum "$1" 2>/dev/null | cut -c1-16; }

# Determine files to compile
TO_COMPILE=()
if [ -n "$TARGET_FILE" ]; then
  [ -f "$TARGET_FILE" ] && TO_COMPILE+=("$TARGET_FILE") || { echo "File not found: $TARGET_FILE"; exit 1; }
elif [ "$MODE" = "all" ]; then
  while IFS= read -r f; do TO_COMPILE+=("$f"); done < <(find "$DAILY_DIR" -name "*.md" -type f 2>/dev/null | sort)
  # Also include build progress files
  while IFS= read -r f; do TO_COMPILE+=("$f"); done < <(find docs/build -name "progress.md" -type f 2>/dev/null | grep -v pipeline-v3 | sort)
else
  # Incremental: find files whose hash differs from state
  for f in "$DAILY_DIR"/*.md; do
    [ -f "$f" ] || continue
    fname=$(basename "$f")
    current=$(file_hash "$f")
    stored=$(jq -r ".ingested[\"$fname\"].hash // \"\"" "$STATE_FILE" 2>/dev/null)
    if [ "$current" != "$stored" ]; then
      TO_COMPILE+=("$f")
    fi
  done
fi

if [ ${#TO_COMPILE[@]} -eq 0 ]; then
  echo "[wiki-compile] nothing to compile (state up-to-date)"
  exit 0
fi

echo "[wiki-compile] files to compile (${#TO_COMPILE[@]}):"
for f in "${TO_COMPILE[@]}"; do echo "  - $f"; done

$DRY && { echo "[wiki-compile] DRY RUN"; exit 0; }

# Read AGENTS.md schema
if [ ! -f "$AGENTS_FILE" ]; then
  echo "ERROR: $AGENTS_FILE not found — wiki schema missing"
  exit 1
fi
SCHEMA=$(cat "$AGENTS_FILE")

# Read current wiki index
WIKI_INDEX=""
[ -f "$INDEX_FILE" ] && WIKI_INDEX=$(cat "$INDEX_FILE")

# Read existing articles for context
EXISTING=""
while IFS= read -r a; do
  rel="${a#$WIKI_DIR/}"
  EXISTING+="### $rel"$'\n\n```markdown\n'"$(cat "$a")"$'\n```\n\n'
done < <(find "$KNOWLEDGE_DIR" "$LESSONS_DIR" "$BUILDS_DIR" "$USER_DIR" -type f -name "*.md" 2>/dev/null | sort)

TOTAL_COST=0
for LOG_FILE_IN in "${TO_COMPILE[@]}"; do
  echo ""
  echo "[wiki-compile] compiling $LOG_FILE_IN..."
  LOG_CONTENT=$(cat "$LOG_FILE_IN")
  LOG_NAME=$(basename "$LOG_FILE_IN")
  TIMESTAMP=$(now_iso)

  PROMPT="You are a knowledge compiler. Your job is to read a source file (daily log, build progress, or lessons log) and extract knowledge into structured wiki articles.

## Schema (AGENTS.md)

${SCHEMA}

## Current Wiki Index

${WIKI_INDEX:-(empty index)}

## Existing Wiki Articles

${EXISTING:-(No existing articles yet)}

## Source File to Compile

**File:** ${LOG_FILE_IN}

${LOG_CONTENT}

## Your Task

Read the source file above and compile it into wiki articles following the schema exactly.

### Rules:

1. **Extract key concepts** — identify 3-7 distinct concepts worth their own article
2. **Create concept articles** in \`wiki/knowledge/concepts/\` — one .md file per concept
   - Use the exact article format from AGENTS.md (YAML frontmatter + sections)
   - Include \`sources:\` in frontmatter pointing to the source file
   - Use \`[[concepts/slug]]\` wikilinks to link to related concepts
   - Write in encyclopedia style — neutral, comprehensive
3. **Create connection articles** in \`wiki/knowledge/connections/\` if this source reveals non-obvious relationships between 2+ existing concepts
4. **Update existing articles** if this source adds new info to concepts already in the wiki
5. **If source is a build progress.md** — also create/update \`wiki/builds/[build-name].md\`
6. **If source is lessons-learned.md or pipeline-error-patterns.md** — create/update \`wiki/lessons/*.md\`
7. **Update \`wiki/index.md\`** — add new entries to the table
   - Each entry: \`| [[path/slug]] | One-line summary | source-file | ${TIMESTAMP:0:10} |\`
8. **Append to \`wiki/log.md\`** — add a timestamped entry:
   \`\`\`
   ## [${TIMESTAMP}] compile | ${LOG_NAME}
   - Source: ${LOG_FILE_IN}
   - Articles created: [[path/x]], [[path/y]]
   - Articles updated: [[path/z]] (if any)
   \`\`\`

### File paths:
- Concept articles: ${CONCEPTS_DIR}/
- Connection articles: ${CONNECTIONS_DIR}/
- Lesson articles: ${LESSONS_DIR}/
- Build summaries: ${BUILDS_DIR}/
- Index: ${INDEX_FILE}
- Log: ${LOG_FILE}

### Quality standards:
- Every article must have complete YAML frontmatter
- Every article must link to at least 2 other articles via [[wikilinks]]
- Key Points section should have 3-5 bullet points
- Details section should have 2+ paragraphs
- Related Concepts section should have 2+ entries
- Sources section should cite the source file with specific claims extracted"

  # Use claude CLI with Write/Edit/Read permissions
  # Note: claude -p in non-interactive mode uses current session permissions
  RESPONSE=$(echo "$PROMPT" | claude -p --allowedTools "Read,Write,Edit,Glob,Grep" 2>&1 | tail -50)
  RC=$?
  echo "  claude exit=$RC"

  # Update state (hash + timestamp)
  if command -v jq >/dev/null 2>&1; then
    HASH=$(file_hash "$LOG_FILE_IN")
    tmp=$(mktemp)
    jq --arg f "$LOG_NAME" \
       --arg h "$HASH" \
       --arg t "$TIMESTAMP" \
       '.ingested[$f] = {hash: $h, compiled_at: $t}' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  fi

  log_to_wiki_log "compile" "source=$LOG_NAME exit=$RC"
done

echo ""
echo "[wiki-compile] done. $(find "$KNOWLEDGE_DIR" "$LESSONS_DIR" "$BUILDS_DIR" -name "*.md" 2>/dev/null | wc -l) articles total."
