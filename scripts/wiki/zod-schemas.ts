// Memory Engine — Zod schemas for validation
// Source: Design D40

import { z } from 'zod';

export const ObservationTypeSchema = z.enum([
  'decision',
  'bugfix',
  'feature',
  'refactor',
  'discovery',
  'change',
  'security_alert',
  'security_note',
]);

export const ObservationExtractionSchema = z.object({
  type: ObservationTypeSchema.describe('Observation type'),
  title: z.string().min(3).max(120),
  subtitle: z.string().max(200).nullish().transform((v) => v ?? null),
  facts: z.array(z.string().min(1).max(200)).max(20).optional().default([]),
  narrative: z.string().min(10).max(5000),
  concepts: z.array(z.string().min(1).max(100)).max(10).optional().default([]),
  files_read: z.array(z.string()).optional().default([]),
  files_modified: z.array(z.string()).optional().default([]),
});

export const SummaryExtractionSchema = z.object({
  request: z.string().max(500).nullable(),
  investigated: z.string().max(1000).nullable(),
  learned: z.string().max(1000).nullable(),
  completed: z.string().max(1000).nullable(),
  next_steps: z.string().max(500).nullable(),
  notes: z.string().max(500).nullable(),
});

export const McpSearchInputSchema = z.object({
  query: z.string().min(1).max(500),
  limit: z.number().int().min(1).max(100).optional().default(20),
  type: ObservationTypeSchema.optional(),
  project: z.string().optional(),
});

export const McpTimelineInputSchema = z.object({
  anchor_id: z.number().int().positive(),
  depth_before: z.number().int().min(0).max(20).optional().default(3),
  depth_after: z.number().int().min(0).max(20).optional().default(3),
});

export const McpGetDetailsInputSchema = z.object({
  ids: z.array(z.number().int().positive()).min(1).max(50),
});

export const QueueEventSchema = z.object({
  session_id: z.string(),
  cwd: z.string(),
  tool_name: z.string(),
  tool_input: z.record(z.string(), z.unknown()),
  tool_response: z.union([z.record(z.string(), z.unknown()), z.string()]),
  hook_event_name: z.literal('PostToolUse'),
  timestamp: z.string(),
  queue_id: z.string(),
  content_hash: z.string().length(24),
});

export type ObservationExtraction = z.infer<typeof ObservationExtractionSchema>;
export type SummaryExtraction = z.infer<typeof SummaryExtractionSchema>;
