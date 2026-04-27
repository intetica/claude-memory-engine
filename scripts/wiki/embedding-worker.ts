// Memory Engine — Voyage embedding worker
// Polls observations WHERE embedding IS NULL → batches 10 → Voyage API → UPDATE.
// Modes:
//   --once     : run one pass, exit when queue empty
//   default    : poll every POLL_INTERVAL ms

import { Pool } from 'pg';

const VOYAGE_API_KEY = process.env.VOYAGE_API_KEY;
const DATABASE_URL = process.env.DATABASE_URL;
const SCHEMA = process.env.MEMORY_SCHEMA || 'claude_memory';

if (!VOYAGE_API_KEY || !DATABASE_URL) {
  process.stderr.write('ERROR: VOYAGE_API_KEY and DATABASE_URL required\n');
  process.exit(2);
}

const VOYAGE_MODEL = process.env.VOYAGE_MODEL ?? 'voyage-3.5-lite';
const VOYAGE_DIM = 1024;
const BATCH_SIZE = 10;
const POLL_INTERVAL_MS = 5 * 60 * 1000; // 5 min between cycles when continuous
const BATCH_GAP_MS = Number(process.env.VOYAGE_BATCH_GAP_MS ?? 25000); // free tier 3 RPM safe
const MAX_TEXT_LEN = 4000;

const ONCE = process.argv.includes('--once');

const pool = new Pool({ connectionString: DATABASE_URL, max: 2 });

interface VoyageEmbedResp {
  object?: string;
  data?: Array<{ embedding: number[]; index: number }>;
  error?: { message?: string };
}

async function callVoyage(texts: string[], attempt = 0): Promise<number[][]> {
  const res = await fetch('https://api.voyageai.com/v1/embeddings', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${VOYAGE_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: VOYAGE_MODEL,
      input: texts,
      output_dimension: VOYAGE_DIM,
      input_type: 'document',
    }),
    signal: AbortSignal.timeout(60_000),
  });

  if (res.status === 429) {
    if (attempt >= 4) throw new Error('Voyage 429 — exhausted backoff');
    // Free tier is 3 RPM → backoff 30s/60s/120s/240s
    const wait = 30_000 * 2 ** attempt;
    process.stderr.write(`Voyage 429, backoff ${wait}ms (attempt ${attempt + 1}/4)\n`);
    await new Promise((r) => setTimeout(r, wait));
    return callVoyage(texts, attempt + 1);
  }

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Voyage HTTP ${res.status}: ${body.slice(0, 300)}`);
  }

  const data = (await res.json()) as VoyageEmbedResp;
  if (!data.data) {
    throw new Error(`Voyage response missing data: ${JSON.stringify(data).slice(0, 300)}`);
  }
  // Sort by index just in case
  const sorted = [...data.data].sort((a, b) => a.index - b.index);
  return sorted.map((d) => d.embedding);
}

async function processBatch(): Promise<number> {
  const result = await pool.query<{
    id: number;
    title: string;
    narrative: string | null;
  }>(
    `SELECT id, title, narrative
     FROM ${SCHEMA}.observations
     WHERE embedding IS NULL
     ORDER BY id
     LIMIT $1`,
    [BATCH_SIZE]
  );

  const rows = result.rows;
  if (rows.length === 0) return 0;

  const texts = rows.map((r) =>
    `${r.title}\n${r.narrative ?? ''}`.slice(0, MAX_TEXT_LEN)
  );

  const embeddings = await callVoyage(texts);

  if (embeddings.length !== rows.length) {
    throw new Error(`Voyage returned ${embeddings.length} vs ${rows.length} rows`);
  }

  for (let i = 0; i < rows.length; i++) {
    const row = rows[i]!;
    const vec = embeddings[i]!;
    if (vec.length !== VOYAGE_DIM) {
      throw new Error(`Vector dim ${vec.length} != ${VOYAGE_DIM}`);
    }
    const vecLiteral = `[${vec.join(',')}]`;
    await pool.query(
      `UPDATE ${SCHEMA}.observations
       SET embedding = $1::vector, embedding_model = $2
       WHERE id = $3`,
      [vecLiteral, `${VOYAGE_MODEL}-2026`, row.id]
    );
  }

  process.stdout.write(`processed ${rows.length} (ids ${rows[0]!.id}–${rows[rows.length - 1]!.id})\n`);
  return rows.length;
}

async function main() {
  process.stdout.write(`embedding-worker started (model=${VOYAGE_MODEL}, dim=${VOYAGE_DIM}, mode=${ONCE ? 'once' : 'continuous'})\n`);

  while (true) {
    let total = 0;
    while (true) {
      const n = await processBatch();
      if (n === 0) break;
      total += n;
      // Free tier: 3 RPM → wait between batches to stay under cap
      await new Promise((r) => setTimeout(r, BATCH_GAP_MS));
    }

    if (ONCE) {
      process.stdout.write(`once mode complete (total ${total})\n`);
      await pool.end();
      process.exit(0);
    }

    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
  }
}

main().catch(async (e) => {
  process.stderr.write(`FATAL: ${e instanceof Error ? e.message : String(e)}\n`);
  try {
    await pool.end();
  } catch {
    /* ignore */
  }
  process.exit(1);
});
