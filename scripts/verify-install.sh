#!/bin/bash
# Voluntary post-install verification.
# Runs after `bash setup.sh`. Confirms MCP server boots, JSON-RPC works,
# DB schema exists, query.sh returns rows.
#
# Usage:  bash scripts/verify-install.sh
# Exit 0 on success, non-zero if any step fails.

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

PASS=0
FAIL=0
note() { printf '  %s\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf '✓ %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '✗ %s\n' "$1"; }

echo "═════════════════════════════════════════════════════"
echo "  claude-memory-engine — install verification"
echo "═════════════════════════════════════════════════════"
echo

# 1. .env present
if [ -f .env ]; then
  ok ".env file present"
else
  no ".env missing — run setup.sh first"
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

SCHEMA="${MEMORY_SCHEMA:-claude_memory}"
SERVER_NAME="${MEMORY_SERVER_NAME:-claude-memory}"

# 2. MCP server compiled
if [ -f dist-scripts/scripts/mcp-memory-server.js ]; then
  ok "MCP server compiled"
else
  no "dist-scripts/scripts/mcp-memory-server.js not found — run npm run mcp:build"
fi

# 3. .mcp.json registered
if [ -f .mcp.json ] && grep -q "$SERVER_NAME" .mcp.json; then
  ok ".mcp.json registers '$SERVER_NAME'"
else
  no ".mcp.json missing or doesn't reference $SERVER_NAME"
fi

# 4. DB reachable + schema exists
if command -v psql >/dev/null 2>&1; then
  if psql "$DATABASE_URL" -tAc "SELECT 1" >/dev/null 2>&1; then
    ok "DB reachable"
    if psql "$DATABASE_URL" -tAc "SELECT 1 FROM pg_namespace WHERE nspname='$SCHEMA'" 2>/dev/null | grep -q 1; then
      ok "schema $SCHEMA exists"
    else
      no "schema $SCHEMA missing — re-apply migrations"
    fi
    OBS_COUNT=$(psql "$DATABASE_URL" -tAc "SELECT count(*) FROM ${SCHEMA}.observations" 2>/dev/null || echo "?")
    note "  observations in DB: $OBS_COUNT"
  else
    no "DB not reachable — check DATABASE_URL"
  fi
else
  no "psql not on PATH — skipped DB checks"
fi

# 5. JSON-RPC handshake
if [ -f dist-scripts/scripts/mcp-memory-server.js ]; then
  HANDSHAKE=$( (echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"verify","version":"1.0"}}}'; sleep 0.3) \
    | timeout 5 node dist-scripts/scripts/mcp-memory-server.js 2>&1 | grep -E '"protocolVersion"' | head -1)
  if [ -n "$HANDSHAKE" ]; then
    ok "MCP server responds to initialize"
  else
    no "MCP server didn't respond to JSON-RPC initialize"
  fi
fi

# 6. tools/list returns 3 tools
if [ -f dist-scripts/scripts/mcp-memory-server.js ]; then
  TOOLS=$( (echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"verify","version":"1.0"}}}'; sleep 0.3; echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'; sleep 0.3) \
    | timeout 5 node dist-scripts/scripts/mcp-memory-server.js 2>&1 | grep -oE '"name":"(search|timeline|get_details)"' | sort -u | wc -l)
  if [ "$TOOLS" -eq 3 ]; then
    ok "all 3 tools registered (search, timeline, get_details)"
  else
    no "expected 3 tools, got $TOOLS"
  fi
fi

# 7. query.sh runs without error
if bash scripts/wiki/query.sh "verification probe" 2>/dev/null | head -1 | grep -q "Найдено\|Found"; then
  ok "query.sh runs against the DB"
else
  no "query.sh failed — DB may be empty (which is fine on fresh install)"
fi

echo
echo "═════════════════════════════════════════════════════"
echo "  PASS: $PASS    FAIL: $FAIL"
echo "═════════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
