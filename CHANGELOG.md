# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] — 2026-04-27

First public release. Extracted from a 6-week production deployment on a single SaaS project (304 observations, 5.8 MB DB, ~$0.40/mo API costs).

### Included
- 4 SQL migrations (templated): schema, indexes, hybrid search RPC, RLS.
- MCP stdio server with 3 tools: `search`, `timeline`, `get_details`.
- PostToolUse hook for per-edit capture (~30 ms latency).
- Queue consumer with claim-confirm + dead-letter (max 3 retries).
- Voyage embedding worker (3.5-lite, 1024-dim, free-tier compatible).
- Cross-platform autostart: systemd (Linux) + launchd (macOS) templates.
- SessionStart hook injecting top-5 recall by topic.
- PreCompact hook for safety capture before context compaction.
- SessionEnd hook for end-of-session summary flush.
- Migration command for existing `MEMORY.md` corpus.
- Interactive `setup.sh` with platform detection.

### Known limitations
- Tested only on Linux (Ubuntu 24.04). macOS launchd templates included but not field-tested by external users.
- No automated suite yet; verification is manual via `Verifying it works` README section.
- Schema parameterization uses string substitution (`{{SCHEMA}}`); proper search_path handling planned for v0.2.

## Planned for [0.2.0]

- Bun runtime compatibility (currently Node 20+ only).
- Optional local Ollama fallback (no Anthropic key needed).
- Public verification suite covering MCP handshake + search round-trip.
- Web UI for browsing observations (auth-gated, optional).
- Cost-optimization for embedding pipeline (batch coalescing).
