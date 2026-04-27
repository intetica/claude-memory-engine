import { describe, it, expect } from 'vitest';
import {
  ObservationTypeSchema,
  ObservationExtractionSchema,
  McpSearchInputSchema,
  McpTimelineInputSchema,
  McpGetDetailsInputSchema,
  QueueEventSchema,
} from '../scripts/wiki/zod-schemas.js';

describe('ObservationTypeSchema', () => {
  it('accepts known types', () => {
    for (const t of ['decision', 'bugfix', 'feature', 'refactor', 'discovery', 'change', 'security_alert', 'security_note']) {
      expect(() => ObservationTypeSchema.parse(t)).not.toThrow();
    }
  });
  it('rejects unknown type', () => {
    expect(() => ObservationTypeSchema.parse('todo')).toThrow();
  });
});

describe('ObservationExtractionSchema', () => {
  const minimal = {
    type: 'feature',
    title: 'Added login',
    narrative: 'A meaningful narrative of at least ten chars.',
  };

  it('accepts minimal valid input + fills defaults', () => {
    const r = ObservationExtractionSchema.parse(minimal);
    expect(r.facts).toEqual([]);
    expect(r.concepts).toEqual([]);
    expect(r.files_read).toEqual([]);
    expect(r.subtitle).toBeNull();
  });

  it('rejects too-short title', () => {
    expect(() => ObservationExtractionSchema.parse({ ...minimal, title: 'ab' })).toThrow();
  });

  it('rejects too-short narrative', () => {
    expect(() => ObservationExtractionSchema.parse({ ...minimal, narrative: 'short' })).toThrow();
  });

  it('caps facts array at 20', () => {
    const facts = Array.from({ length: 21 }, (_, i) => `fact ${i}`);
    expect(() => ObservationExtractionSchema.parse({ ...minimal, facts })).toThrow();
  });
});

describe('McpSearchInputSchema', () => {
  it('requires query', () => {
    expect(() => McpSearchInputSchema.parse({})).toThrow();
  });

  it('defaults limit to 20 when omitted', () => {
    const r = McpSearchInputSchema.parse({ query: 'hello' });
    expect(r.limit).toBe(20);
  });

  it('rejects non-positive limit', () => {
    expect(() => McpSearchInputSchema.parse({ query: 'x', limit: 0 })).toThrow();
    expect(() => McpSearchInputSchema.parse({ query: 'x', limit: 101 })).toThrow();
  });
});

describe('McpTimelineInputSchema', () => {
  it('requires anchor_id', () => {
    expect(() => McpTimelineInputSchema.parse({})).toThrow();
  });

  it('defaults depth_before / depth_after to 3', () => {
    const r = McpTimelineInputSchema.parse({ anchor_id: 42 });
    expect(r.depth_before).toBe(3);
    expect(r.depth_after).toBe(3);
  });

  it('rejects non-positive anchor', () => {
    expect(() => McpTimelineInputSchema.parse({ anchor_id: 0 })).toThrow();
    expect(() => McpTimelineInputSchema.parse({ anchor_id: -1 })).toThrow();
  });
});

describe('McpGetDetailsInputSchema', () => {
  it('requires non-empty ids array', () => {
    expect(() => McpGetDetailsInputSchema.parse({ ids: [] })).toThrow();
    expect(() => McpGetDetailsInputSchema.parse({ ids: [1, 2, 3] })).not.toThrow();
  });

  it('caps at 50 ids', () => {
    const ids = Array.from({ length: 51 }, (_, i) => i + 1);
    expect(() => McpGetDetailsInputSchema.parse({ ids })).toThrow();
  });
});

describe('QueueEventSchema', () => {
  const valid = {
    session_id: 's1',
    cwd: '/tmp',
    tool_name: 'Edit',
    tool_input: { path: '/x.ts' },
    tool_response: { ok: true },
    hook_event_name: 'PostToolUse',
    timestamp: '2026-04-27T18:00:00Z',
    queue_id: 'q1',
    content_hash: 'a'.repeat(24),
  };

  it('accepts a valid event', () => {
    expect(() => QueueEventSchema.parse(valid)).not.toThrow();
  });

  it('rejects content_hash of wrong length', () => {
    expect(() => QueueEventSchema.parse({ ...valid, content_hash: 'a'.repeat(16) })).toThrow();
  });

  it('rejects non-PostToolUse event name', () => {
    expect(() => QueueEventSchema.parse({ ...valid, hook_event_name: 'PreToolUse' })).toThrow();
  });
});
