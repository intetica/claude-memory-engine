#!/bin/bash
# wiki/STATUS.md heartbeat regenerator.
# Fast path: no LLM, only git + filesystem reads. Target: <500ms.
# Triggered by: .git/hooks/post-commit, manual `npm run wiki:status`, SessionStart staleness check.

set -uo pipefail
# Note: no -e — grep returning 1 (no match) is fine, we handle empties with defaults.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$PROJECT_DIR"

STATUS_FILE="wiki/STATUS.md"
mkdir -p wiki

# --- Active build detection ---
# Strategy: active build = build folder whose progress.md does NOT have "Status: COMPLETE"
# Fall back to newest folder if nothing matches.
ACTIVE_BUILD=""
ACTIVE_STAGE=""
ACTIVE_NEXT=""
for dir in $(ls -dt docs/build/*/ 2>/dev/null); do
  PROG="${dir}progress.md"
  [ -f "$PROG" ] || continue
  if grep -qE "^\*\*Status:\*\* (COMPLETE|Done|✅)" "$PROG" 2>/dev/null; then
    continue
  fi
  ACTIVE_BUILD=$(basename "$dir")
  ACTIVE_STAGE=$(grep -oP '^\*\*Status:\*\* \K.*' "$PROG" 2>/dev/null | head -1 | sed 's/ complete.*//; s/ ✅.*//')
  # Next action from Resume Context
  ACTIVE_NEXT=$(awk '/^### Current State/,/^### /' "$PROG" 2>/dev/null | grep -oP '^- \*\*Next action:\*\* \K.*' | head -1 | cut -c1-120)
  break
done

# --- Git state ---
BRANCH=$(git branch --show-current 2>/dev/null || echo "detached")
LAST_COMMIT=$(git log -1 --format="%h %s" 2>/dev/null | cut -c1-100)
LAST_DATE=$(git log -1 --format="%ad" --date=format:"%Y-%m-%d %H:%M" 2>/dev/null)
AHEAD=$(git rev-list --count @{u}..HEAD 2>/dev/null || echo "?")

# --- Recent dev-log tail ---
RECENT_LOG=""
if [ -f "docs/build/development-log.md" ]; then
  RECENT_LOG=$(tail -5 "docs/build/development-log.md" 2>/dev/null | sed 's/^/  /')
fi

# --- Uncompleted tasks count across all active builds ---
OPEN_BUILDS=$(ls -d docs/build/*/ 2>/dev/null | while read d; do
  p="${d}progress.md"
  [ -f "$p" ] && ! grep -qE "^\*\*Status:\*\* (COMPLETE|✅)" "$p" 2>/dev/null && echo 1
done | wc -l)

# --- Maintenance reminders: compile + lint staleness ---
# Shows ⏰ DUE badges in STATUS when maintenance overdue. Zero user effort — agent sees it every session.
STATE_FILE="scripts/wiki/state.json"
COMPILE_DUE_THRESHOLD_DAYS=7
LINT_DUE_THRESHOLD_DAYS=14
UNCOMPILED_THRESHOLD=3

COMPILE_STATUS=""
LINT_STATUS=""

# Count daily logs without matching entry in state.ingested
UNCOMPILED=0
COMPILED_FILES=""
if [ -f "$STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
  COMPILED_FILES=$(jq -r '.ingested | keys[]' "$STATE_FILE" 2>/dev/null | tr '\n' '|' | sed 's/|$//')
fi
shopt -s nullglob
for d in wiki/daily/*.md; do
  [ -f "$d" ] || continue
  fname=$(basename "$d")
  if [ -z "$COMPILED_FILES" ] || ! echo "$COMPILED_FILES" | grep -q "$fname"; then
    UNCOMPILED=$((UNCOMPILED + 1))
  fi
done
shopt -u nullglob

# Last compile timestamp (from state.json)
LAST_COMPILE_ISO=""
DAYS_SINCE_COMPILE=999
if [ -f "$STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
  LAST_COMPILE_ISO=$(jq -r '.last_compile // .ingested | if type=="object" then (to_entries | map(.value.compiled_at) | max // "") else (. // "") end' "$STATE_FILE" 2>/dev/null)
  if [ -n "$LAST_COMPILE_ISO" ] && [ "$LAST_COMPILE_ISO" != "null" ]; then
    LAST_TS=$(date -d "$LAST_COMPILE_ISO" +%s 2>/dev/null || echo 0)
    NOW_TS=$(date +%s)
    if [ "$LAST_TS" -gt 0 ]; then
      DAYS_SINCE_COMPILE=$(( (NOW_TS - LAST_TS) / 86400 ))
    fi
  fi
fi

# Determine COMPILE_STATUS badge
if [ "$DAYS_SINCE_COMPILE" -ge 999 ]; then
  if [ "$UNCOMPILED" -ge "$UNCOMPILED_THRESHOLD" ]; then
    COMPILE_STATUS="⏰ **COMPILE DUE** — $UNCOMPILED uncompiled daily logs, never compiled yet. Run: \`npm run wiki:compile\`"
  elif [ "$UNCOMPILED" -gt 0 ]; then
    COMPILE_STATUS="📝 $UNCOMPILED new daily log(s), never compiled yet ($(( UNCOMPILED_THRESHOLD - UNCOMPILED )) more → DUE)"
  else
    COMPILE_STATUS="✅ no compile needed (no daily logs yet)"
  fi
elif [ "$DAYS_SINCE_COMPILE" -ge "$COMPILE_DUE_THRESHOLD_DAYS" ]; then
  COMPILE_STATUS="⏰ **COMPILE DUE** — last compile ${DAYS_SINCE_COMPILE}d ago (≥${COMPILE_DUE_THRESHOLD_DAYS}d threshold), $UNCOMPILED uncompiled. Run: \`npm run wiki:compile\`"
elif [ "$UNCOMPILED" -ge "$UNCOMPILED_THRESHOLD" ]; then
  COMPILE_STATUS="⏰ **COMPILE DUE** — $UNCOMPILED uncompiled daily logs accumulated (≥${UNCOMPILED_THRESHOLD} threshold). Run: \`npm run wiki:compile\`"
else
  COMPILE_STATUS="✅ compile fresh (${DAYS_SINCE_COMPILE}d ago, $UNCOMPILED pending)"
fi

# Lint staleness
LAST_LINT_ISO=""
DAYS_SINCE_LINT=999
if [ -f "$STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
  LAST_LINT_ISO=$(jq -r '.last_lint // ""' "$STATE_FILE" 2>/dev/null)
  if [ -n "$LAST_LINT_ISO" ] && [ "$LAST_LINT_ISO" != "null" ]; then
    LAST_TS=$(date -d "$LAST_LINT_ISO" +%s 2>/dev/null || echo 0)
    NOW_TS=$(date +%s)
    if [ "$LAST_TS" -gt 0 ]; then
      DAYS_SINCE_LINT=$(( (NOW_TS - LAST_TS) / 86400 ))
    fi
  fi
fi
if [ "$DAYS_SINCE_LINT" -ge "$LINT_DUE_THRESHOLD_DAYS" ]; then
  LINT_STATUS="⏰ lint due (${DAYS_SINCE_LINT}d ago). Run: \`npm run wiki:lint\`"
elif [ "$DAYS_SINCE_LINT" -ge 999 ]; then
  LINT_STATUS="📋 lint never run. Run: \`npm run wiki:lint\`"
else
  LINT_STATUS="✅ lint fresh (${DAYS_SINCE_LINT}d ago)"
fi

# --- Auto-load measurement (excludes rules with `paths:` frontmatter → lazy) ---
# A rule is "lazy" if its first 10 lines contain a `paths:` key after a `---` fence.
AUTO_LOAD_FILES=("CLAUDE.md")
LAZY_COUNT=0
ALWAYS_COUNT=0
for f in .claude/rules/*.md; do
  [ -f "$f" ] || continue
  if head -10 "$f" 2>/dev/null | grep -qE "^paths:"; then
    LAZY_COUNT=$((LAZY_COUNT + 1))
  else
    AUTO_LOAD_FILES+=("$f")
    ALWAYS_COUNT=$((ALWAYS_COUNT + 1))
  fi
done
AUTO_LOAD_LINES=$(wc -l "${AUTO_LOAD_FILES[@]}" 2>/dev/null | tail -1 | awk '{print $1}')
LAZY_RULES=$LAZY_COUNT

# --- Write STATUS.md ---
NOW=$(date "+%Y-%m-%d %H:%M")
cat > "$STATUS_FILE" <<EOF
# Status — $NOW

**Active Build:** ${ACTIVE_BUILD:-—}
**Stage:** ${ACTIVE_STAGE:-—}
**Branch:** \`${BRANCH}\`
**Last commit:** ${LAST_COMMIT}
**Next action:** ${ACTIVE_NEXT:-—}
**Open builds:** ${OPEN_BUILDS} · **Auto-load:** ${AUTO_LOAD_LINES} lines (${ALWAYS_COUNT} rules) · **Lazy rules:** ${LAZY_RULES}

## Maintenance
- ${COMPILE_STATUS}
- ${LINT_STATUS}

## Recent dev-log
\`\`\`
${RECENT_LOG:-  (empty)}
\`\`\`

## Quick nav
- Active folder: [docs/build/${ACTIVE_BUILD}/progress.md](../docs/build/${ACTIVE_BUILD}/progress.md)
- Dev log: [docs/build/development-log.md](../docs/build/development-log.md)
- Wiki index: [wiki/index.md](index.md)

<!-- generated: $(date -u "+%Y-%m-%dT%H:%M:%SZ") by scripts/wiki/update-status.sh -->
EOF

# --- Log to wiki/log.md ---
LOG_FILE="wiki/log.md"
[ -f "$LOG_FILE" ] || echo "# Wiki Log" > "$LOG_FILE"
echo "- $(date -u "+%Y-%m-%dT%H:%M:%SZ") status-update — branch=$BRANCH commit=$(echo "$LAST_COMMIT" | cut -d' ' -f1) active=${ACTIVE_BUILD:-none}" >> "$LOG_FILE"

echo "[wiki] STATUS.md regenerated (${ACTIVE_BUILD:-no active build}, $BRANCH, auto-load=$AUTO_LOAD_LINES lines)"
