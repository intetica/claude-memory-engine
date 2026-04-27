// claude-memory-engine — MCP stdio server with 3 tools (search, timeline, get_details).
// Talks to a Postgres-compatible DB (Supabase, etc.) via direct pg client.

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { Pool } from 'pg';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { z } from 'zod';
import {
  McpSearchInputSchema,
  McpTimelineInputSchema,
  McpGetDetailsInputSchema,
} from './wiki/zod-schemas.js';

// Claude Code launches MCP servers without inheriting the user's shell env.
// Load .env.local / .env manually (no dotenv dependency).
function loadEnvLocal(): void {
  const here = __dirname;
  const candidates = [
    resolve(here, '../../.env.local'),
    resolve(here, '../../../.env.local'),
    resolve(process.cwd(), '.env.local'),
    resolve(here, '../../.env'),
    resolve(process.cwd(), '.env'),
  ];
  for (const path of candidates) {
    try {
      const raw = readFileSync(path, 'utf8');
      for (const line of raw.split('\n')) {
        const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
        if (m && !process.env[m[1]]) {
          const value = m[2].trim().replace(/^"(.*)"$/, '$1').replace(/^'(.*)'$/, '$1');
          process.env[m[1]] = value;
        }
      }
      return;
    } catch {
      // try next candidate
    }
  }
}
loadEnvLocal();

const DATABASE_URL = process.env.DATABASE_URL;
const SCHEMA = process.env.MEMORY_SCHEMA || 'claude_memory';
const PROJECT = process.env.MEMORY_PROJECT || 'default';
const SERVER_NAME = process.env.MEMORY_SERVER_NAME || 'claude-memory';

if (!DATABASE_URL) {
  process.stderr.write('ERROR: DATABASE_URL required\n');
  process.exit(2);
}

let poolLazy: Pool | null = null;
function getPool(): Pool {
  if (!poolLazy) {
    poolLazy = new Pool({ connectionString: DATABASE_URL, max: 4 });
  }
  return poolLazy;
}

const server = new Server(
  { name: SERVER_NAME, version: '1.0.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'search',
      description:
        '3-layer retrieval, layer 1: hybrid keyword+semantic search of memory observations. Returns top-N with rrf_score for further fetch via get_details.',
      inputSchema: {
        type: 'object',
        properties: {
          query: { type: 'string', description: 'Search query (any language)' },
          limit: { type: 'number', description: 'Max results (default 20)' },
          type: { type: 'string', description: 'Filter by observation type' },
          project: { type: 'string', description: `Project filter (default ${PROJECT})` },
        },
        required: ['query'],
      },
    },
    {
      name: 'timeline',
      description:
        '3-layer retrieval, layer 2: chronological context (±days) around an anchor observation.',
      inputSchema: {
        type: 'object',
        properties: {
          anchor_id: { type: 'number', description: 'Observation ID as anchor' },
          depth_before: { type: 'number', description: 'Days before (default 3)' },
          depth_after: { type: 'number', description: 'Days after (default 3)' },
        },
        required: ['anchor_id'],
      },
    },
    {
      name: 'get_details',
      description:
        '3-layer retrieval, layer 3: full data for filtered observation IDs. Logs feedback for ROI metrics.',
      inputSchema: {
        type: 'object',
        properties: {
          ids: { type: 'array', items: { type: 'number' }, description: 'Observation IDs to fetch' },
        },
        required: ['ids'],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const pool = getPool();

  try {
    switch (name) {
      case 'search': {
        const input = McpSearchInputSchema.parse(args);
        const result = await pool.query(
          `SELECT id, title, type, narrative, created_at, rrf_score, semantic_rank, keyword_rank FROM ${SCHEMA}.hybrid_search_observations($1, NULL::vector, $2, $3, $4)`,
          [input.query, input.project ?? PROJECT, input.type ?? null, input.limit]
        );
        const rows = result.rows;
        return {
          content: [
            {
              type: 'text',
              text:
                `Found ${rows.length} observations:\n\n` +
                rows
                  .map(
                    (r) =>
                      `[id=${r.id}] ${r.type}: ${r.title} (rrf=${Number(r.rrf_score ?? 0).toFixed(4)})`
                  )
                  .join('\n'),
            },
          ],
          structuredContent: { observations: rows, count: rows.length, query: input.query },
        };
      }

      case 'timeline': {
        const input = McpTimelineInputSchema.parse(args);
        const result = await pool.query(
          `SELECT id, title, type, created_at, is_anchor FROM ${SCHEMA}.timeline_observations($1, $2, $3, $4)`,
          [input.anchor_id, input.depth_before, input.depth_after, PROJECT]
        );
        const rows = result.rows;
        return {
          content: [
            {
              type: 'text',
              text: rows
                .map((r) => `${r.is_anchor ? '→' : ' '} [id=${r.id}] ${r.type}: ${r.title} (${r.created_at})`)
                .join('\n'),
            },
          ],
          structuredContent: { observations: rows, anchor_id: input.anchor_id },
        };
      }

      case 'get_details': {
        const input = McpGetDetailsInputSchema.parse(args);
        const result = await pool.query(
          `SELECT id, project, session_id, type, title, subtitle, narrative, facts, concepts,
                  files_read, files_modified, prompt_number, discovery_tokens, created_at
           FROM ${SCHEMA}.observations WHERE id = ANY($1::bigint[])`,
          [input.ids]
        );
        const rows = result.rows;
        const nowEpoch = Date.now();
        try {
          const values = input.ids.map((_, i) => `($${i * 2 + 1}, 'mcp_get_details', $${i * 2 + 2})`).join(', ');
          const params: Array<number> = [];
          for (const id of input.ids) {
            params.push(id, nowEpoch);
          }
          await pool.query(
            `INSERT INTO ${SCHEMA}.observation_feedback (observation_id, signal, created_at_epoch) VALUES ${values}`,
            params
          );
        } catch (err) {
          process.stderr.write(`feedback insert failed: ${String(err)}\n`);
        }
        return {
          content: [{ type: 'text', text: JSON.stringify(rows, null, 2) }],
          structuredContent: { observations: rows, count: rows.length },
        };
      }

      default:
        return {
          content: [{ type: 'text', text: `Unknown tool: ${name}` }],
          isError: true,
        };
    }
  } catch (e) {
    if (e instanceof z.ZodError) {
      return {
        content: [{ type: 'text', text: `Invalid input: ${e.message}` }],
        isError: true,
      };
    }
    return {
      content: [{ type: 'text', text: `Tool error: ${e instanceof Error ? e.message : String(e)}` }],
      isError: true,
    };
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  process.stderr.write(`${SERVER_NAME} MCP server started on stdio (schema=${SCHEMA}, project=${PROJECT})\n`);
}

main().catch((e) => {
  process.stderr.write(`Server error: ${e}\n`);
  process.exit(1);
});
