#!/bin/bash
# wiki query — SQL-based hybrid search over ${MEMORY_SCHEMA:-claude_memory}.observations
# Replaces concatenation-based version (kept as query.sh.legacy for fallback).
# Source: Design D11/D26
#
# Usage:
#   bash scripts/wiki/query.sh "вопрос"
#   bash scripts/wiki/query.sh "вопрос" --type=decision
#   bash scripts/wiki/query.sh "вопрос" --limit=10

set -uo pipefail

if [ -n "${CLAUDE_INVOKED_BY:-}" ]; then
  exit 0
fi
export CLAUDE_INVOKED_BY="wiki_query"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

QUESTION=""
TYPE_FILTER=""
LIMIT=20
for arg in "$@"; do
  case "$arg" in
    --type=*) TYPE_FILTER="${arg#*=}" ;;
    --limit=*) LIMIT="${arg#*=}" ;;
    --file-back) ;;  # legacy flag, ignored in new version
    *) [ -z "$QUESTION" ] && QUESTION="$arg" ;;
  esac
done

if [ -z "$QUESTION" ]; then
  echo "Usage: bash scripts/wiki/query.sh \"вопрос\" [--type=decision] [--limit=20]"
  echo ""
  echo "Searches ${MEMORY_SCHEMA:-claude_memory}.observations via hybrid_search RRF."
  echo "Fallback to query.sh.legacy if Supabase unreachable."
  exit 1
fi

# Load DATABASE_URL
if [ -f "$PROJECT_DIR/.env.local" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$PROJECT_DIR/.env.local"
  set +a
fi

if [ -z "${DATABASE_URL:-}" ]; then
  echo "DATABASE_URL missing — falling back to legacy query.sh"
  exec bash "$SCRIPT_DIR/query.sh.legacy" "$QUESTION"
fi

# Build SQL — escape single quotes
QUERY_SQL=$(printf '%s' "$QUESTION" | sed "s/'/''/g")
TYPE_PARAM="NULL"
if [ -n "$TYPE_FILTER" ]; then
  TYPE_PARAM="'$TYPE_FILTER'"
fi

# Query embedding via Voyage (best-effort; on any failure → keyword-only with NULL vector)
QUERY_VEC_LITERAL="NULL"
if [ -n "${VOYAGE_API_KEY:-}" ] && command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  VOYAGE_BODY=$(python3 -c "import json,sys; print(json.dumps({'model':'voyage-3.5-lite','input':[sys.argv[1]],'output_dimension':1024,'input_type':'query'}))" "$QUESTION" 2>/dev/null)
  if [ -n "$VOYAGE_BODY" ]; then
    VOYAGE_RESP=$(curl -sS --max-time 10 https://api.voyageai.com/v1/embeddings \
      -H "Authorization: Bearer $VOYAGE_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$VOYAGE_BODY" 2>/dev/null || true)
    if [ -n "$VOYAGE_RESP" ]; then
      VEC=$(printf '%s' "$VOYAGE_RESP" | python3 -c "import json,sys
try:
    d = json.load(sys.stdin)
    arr = d.get('data',[{}])[0].get('embedding')
    if arr and len(arr) == 1024:
        print('[' + ','.join(repr(float(x)) for x in arr) + ']')
except Exception:
    pass" 2>/dev/null || true)
      if [ -n "$VEC" ]; then
        QUERY_VEC_LITERAL="'$VEC'::vector"
      fi
    fi
  fi
fi

SQL="SELECT id, type, title, regexp_replace(narrative, E'[\\n\\r]+', ' ', 'g'), rrf_score::text, semantic_rank, keyword_rank
FROM ${MEMORY_SCHEMA:-claude_memory}.hybrid_search_observations('$QUERY_SQL', $QUERY_VEC_LITERAL, "${MEMORY_PROJECT:-default}", $TYPE_PARAM, $LIMIT);"

if ! result=$(psql "$DATABASE_URL" -tA -F'|' -c "$SQL" 2>&1); then
  echo "psql error — falling back to legacy query.sh"
  echo "Error: $result" >&2
  exec bash "$SCRIPT_DIR/query.sh.legacy" "$QUESTION"
fi

if [ -z "$result" ]; then
  echo "Ничего не найдено по запросу: \"$QUESTION\""
  exit 0
fi

echo "Найдено по запросу: \"$QUESTION\""
echo ""
echo "$result" | while IFS='|' read -r id type title narrative rrf s_rank k_rank; do
  echo "[id=$id] $type · $title (rrf=$rrf)"
  if [ -n "$narrative" ]; then
    echo "  ${narrative:0:200}..."
  fi
  echo ""
done
