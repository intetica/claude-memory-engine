#!/bin/bash
# wiki lint — 10 structural checks + optional LLM contradictions check.
# Usage:
#   bash scripts/wiki/lint.sh                  # all structural checks
#   bash scripts/wiki/lint.sh --structural     # same (explicit)
#   bash scripts/wiki/lint.sh --contradictions # include LLM contradictions check
#   bash scripts/wiki/lint.sh --fix            # auto-fix missing backlinks
#
# Exit codes: 0 = ok, 1 = errors found, 2 = warnings only.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

MODE="structural"
FIX=false
for arg in "$@"; do
  case "$arg" in
    --contradictions) MODE="all" ;;
    --fix) FIX=true ;;
    --structural) MODE="structural" ;;
  esac
done

ERRORS=0
WARNINGS=0
SUGGESTIONS=0
REPORT="$WIKI_DIR/lint-$(today_iso).md"

echo "# Wiki Lint Report — $(now_iso)" > "$REPORT"
echo "" >> "$REPORT"

err()  { echo "- **[error]** $1" >> "$REPORT"; ERRORS=$((ERRORS+1)); }
warn() { echo "- **[warn]** $1" >> "$REPORT"; WARNINGS=$((WARNINGS+1)); }
sug()  { echo "- **[sug]** $1" >> "$REPORT"; SUGGESTIONS=$((SUGGESTIONS+1)); }

# ─── Collect all wiki articles ───
mapfile -t ARTICLES < <(find "$KNOWLEDGE_DIR" "$LESSONS_DIR" "$BUILDS_DIR" "$USER_DIR" -type f -name "*.md" 2>/dev/null | sort)

# Build link index: "slug -> filepath"
declare -A ARTICLE_PATHS
for a in "${ARTICLES[@]}"; do
  rel="${a#$WIKI_DIR/}"          # e.g. knowledge/concepts/pipeline.md
  slug="${rel%.md}"              # e.g. knowledge/concepts/pipeline
  ARTICLE_PATHS["$slug"]="$a"
  # Also register shorthand without knowledge/ prefix
  short="${slug#knowledge/}"      # e.g. concepts/pipeline
  ARTICLE_PATHS["$short"]="$a"
done

echo "## 1. Broken wikilinks" >> "$REPORT"
for a in "${ARTICLES[@]}"; do
  while IFS= read -r link; do
    # strip [[  ]] and any | alias
    target="${link#[[}"; target="${target%]]}"; target="${target%%|*}"
    # skip daily/ refs (they are sources, may not exist if gitignored)
    [[ "$target" == daily/* ]] && continue
    # skip external/http
    [[ "$target" == http* ]] && continue
    # strip .md if present
    target="${target%.md}"
    if [ -z "${ARTICLE_PATHS[$target]:-}" ] && [ -z "${ARTICLE_PATHS[knowledge/$target]:-}" ]; then
      err "\`$(basename "$a")\` → \`[[${target}]]\` not found"
    fi
  done < <(grep -oE '\[\[[^]]+\]\]' "$a" 2>/dev/null)
done
[ "$ERRORS" -eq 0 ] && echo "- (none)" >> "$REPORT"
echo "" >> "$REPORT"

echo "## 2. Orphan pages (0 inbound links)" >> "$REPORT"
for a in "${ARTICLES[@]}"; do
  rel="${a#$WIKI_DIR/}"
  slug="${rel%.md}"
  short="${slug#knowledge/}"
  # Count inbound: any other article linking to this slug or shorthand
  inbound=0
  for b in "${ARTICLES[@]}"; do
    [ "$a" = "$b" ] && continue
    if grep -qE "\[\[($slug|$short)(\||\])" "$b" 2>/dev/null; then
      inbound=$((inbound+1))
    fi
  done
  # index.md and STATUS.md also count as inbound sources
  if grep -qE "\[\[($slug|$short)(\||\])" "$INDEX_FILE" 2>/dev/null; then
    inbound=$((inbound+1))
  fi
  if [ "$inbound" -eq 0 ]; then
    warn "\`$rel\` has 0 inbound links (orphan)"
  fi
done
echo "" >> "$REPORT"

echo "## 3. Orphan sources (daily logs not compiled)" >> "$REPORT"
ensure_state
for d in "$DAILY_DIR"/*.md; do
  [ -f "$d" ] || continue
  rel=$(basename "$d")
  if ! grep -q "\"$rel\"" "$STATE_FILE" 2>/dev/null; then
    warn "\`daily/$rel\` not yet compiled (run compile.sh)"
  fi
done
echo "" >> "$REPORT"

echo "## 4. Stale articles (source hash changed)" >> "$REPORT"
if command -v jq >/dev/null 2>&1 && [ -f "$STATE_FILE" ]; then
  ingested=$(jq -r '.ingested | to_entries[] | "\(.key)|\(.value.hash)"' "$STATE_FILE" 2>/dev/null)
  while IFS='|' read -r fname stored_hash; do
    [ -z "$fname" ] && continue
    src="$DAILY_DIR/$fname"
    [ -f "$src" ] || continue
    current_hash=$(sha256sum "$src" | cut -c1-16)
    if [ "$current_hash" != "$stored_hash" ]; then
      warn "\`daily/$fname\` changed since last compile (hash mismatch)"
    fi
  done <<< "$ingested"
fi
echo "" >> "$REPORT"

echo "## 5. Missing backlinks (A→B but not B→A)" >> "$REPORT"
for a in "${ARTICLES[@]}"; do
  rel_a="${a#$WIKI_DIR/}"
  slug_a="${rel_a%.md}"
  short_a="${slug_a#knowledge/}"
  while IFS= read -r link; do
    target="${link#[[}"; target="${target%]]}"; target="${target%%|*}"
    target="${target%.md}"
    [[ "$target" == daily/* ]] && continue
    [[ "$target" == http* ]] && continue
    target_path="${ARTICLE_PATHS[$target]:-${ARTICLE_PATHS[knowledge/$target]:-}}"
    [ -z "$target_path" ] && continue
    # Check if target links back to source
    if ! grep -qE "\[\[($slug_a|$short_a)(\||\])" "$target_path" 2>/dev/null; then
      sug "\`$rel_a\` → \`$target\` but no backlink $([ "$FIX" = true ] && echo '(auto-fix enabled)')"
      if [ "$FIX" = true ]; then
        # Append related link at bottom of target
        if ! grep -q "^## Related" "$target_path"; then
          echo -e "\n## Related\n" >> "$target_path"
        fi
        echo "- [[${short_a}]]" >> "$target_path"
      fi
    fi
  done < <(grep -oE '\[\[[^]]+\]\]' "$a" 2>/dev/null)
done
echo "" >> "$REPORT"

echo "## 6. Sparse articles (<200 words)" >> "$REPORT"
for a in "${ARTICLES[@]}"; do
  # Exclude YAML frontmatter from word count
  words=$(awk 'BEGIN{inFm=0;count=0} /^---$/{inFm=!inFm;next} !inFm{count+=NF} END{print count}' "$a")
  if [ "$words" -lt 200 ]; then
    rel="${a#$WIKI_DIR/}"
    sug "\`$rel\` is sparse ($words words)"
  fi
done
echo "" >> "$REPORT"

echo "## 7. Missing frontmatter" >> "$REPORT"
for a in "${ARTICLES[@]}"; do
  rel="${a#$WIKI_DIR/}"
  first_line=$(head -1 "$a")
  if [ "$first_line" != "---" ]; then
    err "\`$rel\` missing YAML frontmatter fence"
    continue
  fi
  # Check required fields
  for field in title sources created updated; do
    if ! awk '/^---$/{n++;if(n==2)exit} n==1' "$a" | grep -q "^$field:"; then
      err "\`$rel\` missing frontmatter field: \`$field\`"
    fi
  done
done
echo "" >> "$REPORT"

echo "## 8. Stale STATUS.md" >> "$REPORT"
if [ -f "$STATUS_FILE" ]; then
  status_mtime=$(stat -c %Y "$STATUS_FILE" 2>/dev/null || stat -f %m "$STATUS_FILE" 2>/dev/null || echo 0)
  head_time=$(cd "$PROJECT_DIR" && git log -1 --format=%ct 2>/dev/null || echo 0)
  diff=$((head_time - status_mtime))
  if [ "$diff" -gt 300 ]; then
    warn "\`wiki/STATUS.md\` older than HEAD by ${diff}s (>5 min, run update-status.sh)"
  fi
else
  err "\`wiki/STATUS.md\` does not exist"
fi
echo "" >> "$REPORT"

echo "## 9. Missing build summaries" >> "$REPORT"
for prog in docs/build/*/progress.md; do
  [ -f "$prog" ] || continue
  build_name=$(basename "$(dirname "$prog")")
  [[ "$build_name" == pipeline-v3* ]] && continue
  [[ "$build_name" == marketplace-analytics ]] && continue
  if grep -qE "^\*\*Status:\*\* (COMPLETE|✅)" "$prog" 2>/dev/null; then
    summary="$BUILDS_DIR/${build_name}.md"
    if [ ! -f "$summary" ]; then
      warn "build \`$build_name\` COMPLETE but no \`wiki/builds/${build_name}.md\`"
    fi
  fi
done
echo "" >> "$REPORT"

echo "## 10. Orphan lessons (active but not triggered recently)" >> "$REPORT"
# Placeholder: no build_count data yet. Mark future check.
echo "- _check pending implementation (requires build_count tracking)_" >> "$REPORT"
echo "" >> "$REPORT"

# LLM contradictions check
if [ "$MODE" = "all" ]; then
  echo "## 11. LLM Contradictions" >> "$REPORT"
  if command -v claude >/dev/null 2>&1 && [ ${#ARTICLES[@]} -gt 0 ]; then
    # Concatenate all articles into one context
    CONTENT=""
    for a in "${ARTICLES[@]}"; do
      rel="${a#$WIKI_DIR/}"
      CONTENT+="### $rel"$'\n\n'"$(cat "$a")"$'\n\n---\n\n'
    done
    PROMPT="Review this knowledge base for contradictions, inconsistencies, or conflicting claims across articles.

## Knowledge Base

${CONTENT}

## Instructions

Look for:
- Direct contradictions (article A says X, article B says not-X)
- Inconsistent recommendations
- Outdated information conflicting with newer entries

For each issue output EXACTLY one line:
CONTRADICTION: [file1] vs [file2] - description
INCONSISTENCY: [file] - description

If no issues found, output exactly: NO_ISSUES

No preamble, no explanation, just formatted lines."
    RESP=$(echo "$PROMPT" | claude -p 2>/dev/null | head -100)
    if echo "$RESP" | grep -q "NO_ISSUES"; then
      echo "- (none)" >> "$REPORT"
    else
      echo "$RESP" | while IFS= read -r line; do
        if [[ "$line" == CONTRADICTION* ]] || [[ "$line" == INCONSISTENCY* ]]; then
          echo "- **[warn]** $line" >> "$REPORT"
          WARNINGS=$((WARNINGS+1))
        fi
      done
    fi
  else
    echo "- skipped (claude CLI not available or no articles)" >> "$REPORT"
  fi
  echo "" >> "$REPORT"
fi

# Summary
echo "## Summary" >> "$REPORT"
echo "" >> "$REPORT"
echo "- Errors: $ERRORS" >> "$REPORT"
echo "- Warnings: $WARNINGS" >> "$REPORT"
echo "- Suggestions: $SUGGESTIONS" >> "$REPORT"
echo "- Articles checked: ${#ARTICLES[@]}" >> "$REPORT"

# Update state
if command -v jq >/dev/null 2>&1 && [ -f "$STATE_FILE" ]; then
  tmp=$(mktemp)
  jq --arg t "$(now_iso)" '.last_lint = $t' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
fi

log_to_wiki_log "lint" "errors=$ERRORS warnings=$WARNINGS suggestions=$SUGGESTIONS articles=${#ARTICLES[@]}"

# Output
echo "[wiki-lint] errors=$ERRORS warnings=$WARNINGS suggestions=$SUGGESTIONS articles=${#ARTICLES[@]}"
echo "[wiki-lint] Report: $REPORT"

if [ "$ERRORS" -gt 0 ]; then
  exit 1
elif [ "$WARNINGS" -gt 0 ]; then
  exit 2
else
  exit 0
fi
