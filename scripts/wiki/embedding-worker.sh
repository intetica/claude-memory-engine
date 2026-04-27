#!/bin/bash
# Memory Engine — Voyage embedding worker (bash wrapper)
# Loads .env.local, runs TS worker via tsx.
# Usage: bash scripts/wiki/embedding-worker.sh [--once]

set -uo pipefail

if [ -n "${CLAUDE_INVOKED_BY:-}" ]; then
  exit 0
fi
export CLAUDE_INVOKED_BY="wiki_embedding_worker"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="$SCRIPT_DIR/embedding-worker.log"

ENV_FILE="$PROJECT_DIR/.env.local"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

TSX_BIN="$PROJECT_DIR/node_modules/.bin/tsx"
[ -x "$TSX_BIN" ] || TSX_BIN="tsx"

log_ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

log_ts "starting embedding-worker $*"
"$TSX_BIN" "$SCRIPT_DIR/embedding-worker.ts" "$@" 2>&1 | tee -a "$LOG_FILE"
log_ts "embedding-worker exited"
