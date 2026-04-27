#!/bin/bash
# claude-memory-engine — interactive setup.
# Run from project root: bash setup.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

echo "═══════════════════════════════════════════════════════"
echo "  claude-memory-engine — setup"
echo "═══════════════════════════════════════════════════════"
echo

# 1. Detect platform
PLATFORM="unknown"
case "$(uname -s)" in
  Linux*)  PLATFORM="linux";;
  Darwin*) PLATFORM="darwin";;
  *)       echo "❌ Unsupported platform: $(uname -s). Linux and macOS only."; exit 1;;
esac
echo "✓ Platform: $PLATFORM"

# 2. Detect Node
if ! command -v node >/dev/null 2>&1; then
  echo "❌ Node.js not found. Install Node 20+ first."
  exit 1
fi
NODE_BIN=$(command -v node)
NODE_BIN_DIR=$(dirname "$NODE_BIN")
echo "✓ Node: $(node --version) at $NODE_BIN_DIR"

# 3. Project metadata
read -rp "Project tag (slug, used in DB project column) [my-project]: " PROJECT_TAG
PROJECT_TAG="${PROJECT_TAG:-my-project}"

read -rp "Memory schema name [claude_memory]: " SCHEMA
SCHEMA="${SCHEMA:-claude_memory}"

read -rp "MCP server name (will appear as mcp__<name>__search) [claude-memory]: " SERVER_NAME
SERVER_NAME="${SERVER_NAME:-claude-memory}"

# 4. Secrets — prompt only if .env doesn't exist
if [ -f .env ]; then
  echo "✓ .env already exists — skipping prompts."
else
  echo
  echo "Now we need 3 secrets. They go into .env (gitignored)."
  echo
  read -rp "DATABASE_URL (postgresql://...): " DATABASE_URL
  read -rsp "ANTHROPIC_API_KEY (sk-ant-...): " ANTHROPIC_API_KEY
  echo
  read -rsp "VOYAGE_API_KEY (pa-...): " VOYAGE_API_KEY
  echo

  cat > .env <<EOF
DATABASE_URL="$DATABASE_URL"
MEMORY_SCHEMA="$SCHEMA"
MEMORY_PROJECT="$PROJECT_TAG"
MEMORY_SERVER_NAME="$SERVER_NAME"
ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
VOYAGE_API_KEY="$VOYAGE_API_KEY"
EOF
  chmod 600 .env
  echo "✓ .env written (chmod 600)"
fi

# Symlink .env → .env.local so scripts that look for .env.local pick it up.
if [ ! -e .env.local ]; then
  ln -sf .env .env.local
  echo "✓ .env.local → .env (symlink for compatibility)"
fi

# 5. Install npm deps
echo
echo "→ npm install..."
npm install --silent

# 6. Apply migrations: render templates → real .sql, run via psql.
echo
echo "→ Applying SQL migrations to schema $SCHEMA..."
mkdir -p supabase/migrations/.rendered
for tpl in supabase/migrations/*.sql.template; do
  out="supabase/migrations/.rendered/$(basename "${tpl%.template}")"
  sed -e "s/{{SCHEMA}}/$SCHEMA/g" -e "s/{{PROJECT}}/$PROJECT_TAG/g" "$tpl" > "$out"
done

# Load DATABASE_URL from .env for psql.
set -a
source .env
set +a

if ! command -v psql >/dev/null 2>&1; then
  echo "⚠️  psql not found. Migrations are rendered at supabase/migrations/.rendered/ — apply them manually."
else
  for sql in supabase/migrations/.rendered/*.sql; do
    echo "  → $(basename "$sql")"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$sql" >/dev/null
  done
  echo "✓ Migrations applied."
fi

# 7. Build MCP server (TypeScript → JS)
echo
echo "→ Building MCP server..."
npm run mcp:build --silent
echo "✓ Built: dist-scripts/scripts/mcp-memory-server.js"

# 8. Render .mcp.json from template
sed "s/{{SERVER_NAME}}/$SERVER_NAME/g" .mcp.json.template > .mcp.json
echo "✓ .mcp.json generated"

# 9. Render .claude/settings.json from template (only if doesn't exist)
mkdir -p .claude
if [ ! -f .claude/settings.json ]; then
  cp .claude/settings.json.template .claude/settings.json
  echo "✓ .claude/settings.json generated"
else
  echo "ℹ  .claude/settings.json already exists — leaving alone. Merge hooks from .claude/settings.json.template manually if needed."
fi

# 10. Autostart workers (per-platform)
echo
read -rp "Install autostart for queue-consumer + embedding-worker? [Y/n]: " AUTOSTART
AUTOSTART="${AUTOSTART:-Y}"
if [[ "$AUTOSTART" =~ ^[Yy] ]]; then
  if [ "$PLATFORM" = "linux" ]; then
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    for tpl in systemd/*.service.template; do
      base=$(basename "${tpl%.template}")
      target="$UNIT_DIR/cme-${PROJECT_TAG}-$base"
      sed -e "s|{{PROJECT}}|$PROJECT_TAG|g" \
          -e "s|{{PROJECT_DIR}}|$PROJECT_DIR|g" \
          -e "s|{{NODE_BIN_DIR}}|$NODE_BIN_DIR|g" \
          "$tpl" > "$target"
    done
    systemctl --user daemon-reload
    systemctl --user enable --now \
      "cme-${PROJECT_TAG}-queue-consumer.service" \
      "cme-${PROJECT_TAG}-embedding-worker.service"
    echo "✓ systemd user services installed and started."
    echo "  Status:  systemctl --user status cme-${PROJECT_TAG}-queue-consumer cme-${PROJECT_TAG}-embedding-worker"
  elif [ "$PLATFORM" = "darwin" ]; then
    AGENT_DIR="$HOME/Library/LaunchAgents"
    mkdir -p "$AGENT_DIR"
    for tpl in launchd/*.plist.template; do
      base=$(basename "${tpl%.template}")
      target="$AGENT_DIR/${base/.plist/.${PROJECT_TAG}.plist}"
      sed -e "s|{{PROJECT}}|$PROJECT_TAG|g" \
          -e "s|{{PROJECT_DIR}}|$PROJECT_DIR|g" \
          -e "s|{{NODE_BIN_DIR}}|$NODE_BIN_DIR|g" \
          "$tpl" > "$target"
      launchctl unload "$target" 2>/dev/null || true
      launchctl load "$target"
    done
    echo "✓ launchd agents installed and loaded."
    echo "  Status:  launchctl list | grep claude-memory-engine"
  fi
else
  echo "ℹ  Autostart skipped. Run workers manually:"
  echo "     npm run memory:queue-consumer &"
  echo "     npm run memory:embedding-worker &"
fi

echo
echo "═══════════════════════════════════════════════════════"
echo "  ✅ Setup complete"
echo "═══════════════════════════════════════════════════════"
echo
echo "Next steps:"
echo "  1. Restart Claude Code in this directory."
echo "  2. Verify MCP tools: ask Claude to call mcp__${SERVER_NAME}__search"
echo "  3. Memory will accumulate as you work — every Edit/Write/Bash captured."
echo
