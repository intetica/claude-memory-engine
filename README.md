# claude-memory-engine

[![CI](https://github.com/intetica/claude-memory-engine/actions/workflows/ci.yml/badge.svg)](https://github.com/intetica/claude-memory-engine/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Node 20+](https://img.shields.io/badge/node-%3E%3D20-brightgreen)](https://nodejs.org/)

Memory for [Claude Code](https://docs.claude.com/en/docs/claude-code), backed by Postgres + pgvector. Auto-captures every `Edit` / `Write` / `Bash`, exposes 3 [MCP](https://modelcontextprotocol.io/) tools to Claude, recalls relevant context at session start.

> **Status:** in daily use on one production project (6 weeks, 304 observations, 5.8 MB DB, ~$0.40/mo in API costs). Open-sourced today. Looking for second-project trial — issues welcome.

---

## What it does

- **PostToolUse hook** → JSON event into a queue.
- **Background worker** (systemd / launchd) → Anthropic Haiku 4.5 extracts `{type, title, narrative, facts, concepts}` → Postgres.
- **Embedding worker** → Voyage 3.5-lite → pgvector (1024-dim).
- **MCP server** exposes 3 tools to Claude: `search`, `timeline`, `get_details`.
- **SessionStart hook** auto-injects top-5 observations matching the active topic.

Search is keyword + semantic, combined via [Reciprocal Rank Fusion](https://plg.uwaterloo.ca/~gvcormac/cormacksigir09-rrf.pdf). Catches both exact-term matches and conceptual ones.

---

## Real data

Live from the project that uses this:

```sql
$ psql "$DATABASE_URL" -c "
    SELECT id, type, title FROM claude_memory.observations
    ORDER BY id DESC LIMIT 7"

 id  |   type   |                                    title
-----+----------+-----------------------------------------------------------------------------
 314 | refactor | Рефакторинг сигнатуры MotivationCalcPage: props вместо деструктуризации
 313 | feature  | Добавлена обработка slug и проверка клиники в MotivationCalcPage
 312 | change   | Обновлён README.md для топ-конверсии
 311 | feature  | Добавлена поддержка clinicSlug в форме логина
 310 | refactor | Рефакторинг README.md: улучшена структура, добавлены сравнения и инструкции
 309 | feature  | Добавлена поддержка clinicSlug в LoginForm
 308 | refactor | Рефакторинг страницы логина: серверный рендер заголовка клиники
```

Real session in Claude Code:

```
> What did we decide about pricing storage?

  Called claude-memory 2 times (search + get_details)

> Pricing is stored as integer kopecks (not float rubles), set in
  CLAUDE.md and observation [id=87]. Reason: floating-point drift.
```

That call to `claude-memory` happened automatically — Claude saw the question was about past decisions and chose to ask memory.

---

## Comparison

|  | claude-memory-engine | [coleam00/claude-memory-compiler](https://github.com/coleam00/claude-memory-compiler) | Claude Code built-in |
|---|---|---|---|
| Captures every edit | ✅ PostToolUse hook | ❌ session boundaries | ❌ model decides |
| Search across history | ✅ BM25 + pgvector + RRF | grep + LLM Q&A | flat MEMORY.md |
| Claude calls memory natively | ✅ 3 MCP tools | external CLI | limited |
| Auto-injects context at start | ✅ top-5 by topic | ✅ static index | ✅ MEMORY.md |
| Multi-project, multi-machine | ✅ DB schemas | folder per project | ❌ |
| Dedup via content hash | ✅ | ❌ | ❌ |
| Autostart workers | ✅ systemd + launchd | manual | — |
| GitHub stars | 0 (today) | 925 | — |
| Setup time | 5 min | 2 min | 0 |

`claude-memory-compiler` is the popular markdown-based approach (Karpathy KB style). This project takes a different tradeoff — heavier setup, but gives Claude native search across structured observations. Pick by the table.

Honest credit: I learned a lot from coleam00's code. The Quick Start trick (telling an AI agent to install via prompt) is borrowed directly. The compile / lint / query script names match for portability.

---

## Quick Start (via AI agent)

Tell Claude in any project:

> Clone https://github.com/intetica/claude-memory-engine into a `.memory/` folder. Run `bash .memory/setup.sh` and walk me through prompts. After it finishes, restart yourself so the MCP server loads.

Setup will:
1. Detect platform (Linux / macOS), Node path.
2. Ask 3 questions: project tag, Postgres URL, API keys.
3. Apply 4 SQL migrations.
4. Compile the MCP server, register it.
5. Install systemd / launchd workers (auto-start on login).

After Claude restarts, 3 new tools appear: `mcp__claude-memory__search`, `mcp__claude-memory__timeline`, `mcp__claude-memory__get_details`.

## Manual install

```bash
git clone https://github.com/intetica/claude-memory-engine
cd claude-memory-engine
bash setup.sh
```

Requirements: Node ≥ 20, Postgres ≥ 14 with pgvector (Supabase free tier works), Anthropic API key, Voyage API key, Linux or macOS.

---

## Architecture

```
You edit a file
      │
      ▼
PostToolUse hook → wiki/queue/*.json (event, <30 ms)
      │
      ▼
queue-consumer (systemd / launchd, restart-always)
      │   Anthropic Haiku 4.5 — extract {type, title, narrative, facts, concepts}
      ▼
Postgres (claude_memory.observations)
      │                                         ▲
      ▼                                         │
embedding-worker → Voyage 3.5-lite              │
   (1024-dim vector → pgvector HNSW index)      │
                                                │
On session begin: query.sh → top-5 by topic ────┘
   → injected into Claude's context before your first message

When Claude wants memory:
   mcp__claude-memory__search → hybrid_search_observations() with RRF
   mcp__claude-memory__get_details → full row + log feedback
```

---

## Why these choices

**Postgres.** You probably already have one (Supabase free tier suffices). pgvector + tsvector is the most boring, reliable stack on the planet. No vector DB lock-in. `pg_dump` for backup.

**MCP.** Claude reads memory natively — no copy-paste, no CLI invocation. The model itself decides when to query.

**Voyage 3.5-lite.** $0.02 per million tokens. Outperforms OpenAI text-embedding-3-small on retrieval at 1/10 the cost.

**Per-edit capture instead of session boundaries.** Most "ah-ha" moments happen mid-session: a small refactor, a switched library, a fixed bug. Capturing only at session end loses the fine-grained context. (Mid-session capture also has a downside — more API calls, more noise. Trade-off discussed in `docs/design.md`.)

---

## Cost

Real numbers from the project that uses this (304 observations over 6 weeks):

| Resource | Cost |
|---|---|
| Anthropic Haiku (extraction) | ~$0.30 / month |
| Voyage embeddings | ~$0.10 / month |
| Postgres storage | 5.8 MB total |
| Worker CPU | <2% on a 2018 laptop |

**~$0.40 / month total** at moderate use.

---

## Configuration

All settings in `.env` (gitignored):

| Variable | Default | Purpose |
|---|---|---|
| `DATABASE_URL` | — | Postgres connection string |
| `MEMORY_SCHEMA` | `claude_memory` | Schema name. Per-project isolation. |
| `MEMORY_PROJECT` | `default` | Project tag, used as filter in `search`. |
| `MEMORY_SERVER_NAME` | `claude-memory` | MCP server name. Tools as `mcp__<name>__*`. |
| `ANTHROPIC_API_KEY` | — | Haiku extraction + LLM compile |
| `VOYAGE_API_KEY` | — | Embeddings |

Multi-project, one DB:
- Project A: `MEMORY_SCHEMA=projecta_memory`, `MEMORY_PROJECT=alpha`
- Project B: `MEMORY_SCHEMA=projectb_memory`, `MEMORY_PROJECT=beta`

Schemas are isolated; projects don't bleed.

---

## CLI commands

```bash
npm run memory:query "your question"   # search without invoking Claude
npm run memory:status                  # regen wiki/STATUS.md
npm run memory:compile                 # compile daily logs into wiki articles (LLM)
npm run memory:lint                    # 10 health-checks on wiki
npm run memory:migrate:dry             # import existing MEMORY.md (preview)
npm run memory:migrate                 # actually import
```

---

## Verifying it works

After `bash setup.sh` and Claude restart, run from project root:

```bash
# 1. MCP server starts and loads .env
unset DATABASE_URL && timeout 3 node dist-scripts/scripts/mcp-memory-server.js
# expect: claude-memory MCP server started on stdio (...)

# 2. JSON-RPC handshake
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
  | node dist-scripts/scripts/mcp-memory-server.js | head -1
# expect: {"result":{"protocolVersion":"2024-11-05",...

# 3. Tools registered with Claude
psql "$DATABASE_URL" -c "SELECT count(*) FROM claude_memory.observations"
# any count is fine; 0 right after install
```

---

## Files Claude Code reads

| File | Purpose |
|---|---|
| `.mcp.json` | Registers the MCP server |
| `.claude/settings.json` | SessionStart, PostToolUse, PreCompact, SessionEnd hooks |
| `.claude/hooks/session-start-memory.sh` | Top-5 recall at session begin |
| `scripts/wiki/posttooluse-capture.sh` | Captures every edit |

---

## Troubleshooting

**MCP tools don't appear after restart.**
`ls dist-scripts/scripts/mcp-memory-server.js` — built? `npm run mcp:server` — server runs? If `ERROR: DATABASE_URL required`, the server can't find `.env` (must be in project root).

**Workers not running.**
- Linux: `systemctl --user status cme-<project>-queue-consumer cme-<project>-embedding-worker`
- macOS: `launchctl list | grep claude-memory-engine`
- Logs: `tail -f scripts/wiki/queue-consumer.log`

**Queue grows but observations don't appear.**
Anthropic key valid? `wiki/queue/.deadletter/` — anything there? DB reachable? `psql "$DATABASE_URL" -c "SELECT count(*) FROM claude_memory.observations"`.

**Search returns nothing.**
Embeddings present? `psql "$DATABASE_URL" -c "SELECT count(*) FILTER (WHERE embedding IS NOT NULL) FROM claude_memory.observations"`. Worker should fill within minutes.

---

## What's not included

This is **memory infrastructure only** — no agent framework, no opinionated workflow. The original project I extracted from has a 9-stage pipeline (`/build`, `/quick-task`, etc.) on top — too project-specific to ship publicly.

---

## Roadmap

See [CHANGELOG.md](CHANGELOG.md). Planned for v0.2:
- Bun runtime support (currently Node-only).
- Optional local Ollama fallback for extraction (no Anthropic key required).
- Web UI for browsing observations (auth-gated).
- Public test suite covering MCP handshake + search.

---

## Contributing

Issues welcome. PRs especially welcome on:
- macOS launchd (currently Linux-only really tested).
- Schema parameterization edge cases.
- Cost-optimization for embedding pipeline.

[Issue template](.github/ISSUE_TEMPLATE/bug.md). [PR template](.github/pull_request_template.md).

---

## License

MIT — see [LICENSE](LICENSE).
