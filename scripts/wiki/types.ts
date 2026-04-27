// claude-memory-engine — types for queue consumer + workers

export interface ToolEvent {
  session_id: string;
  cwd: string;
  tool_name: string;
  tool_input: Record<string, unknown>;
  tool_response: Record<string, unknown> | string;
  hook_event_name: 'PostToolUse';
  timestamp: string;
}

export interface QueueEvent extends ToolEvent {
  queue_id: string;
  content_hash: string;
  queue_file_path: string;
}

export interface ExtractedObservation {
  observation_id: number | null;
  content_hash: string;
  status: 'created' | 'dedup' | 'failed';
  error?: string;
  retry_count?: number;
}

export interface ConsumerConfig {
  queue_dir: string;
  batch_size: number;
  poll_interval_ms: number;
  max_retries: number;
  anthropic_api_key: string;
  supabase_url: string;
  supabase_service_role_key: string;
}

export interface ConsumerStats {
  events_processed: number;
  events_failed: number;
  dedup_hits: number;
  avg_processing_time_ms: number;
  last_run_at: string;
}

export interface MigrationConfig {
  memory_dir: string;
  project: string;
  batch_size: number;
  classify_by_name: boolean;
  supabase_url: string;
  supabase_service_role_key: string;
  dry_run: boolean;
}

export interface MigrationResult {
  total_files: number;
  migrated: number;
  failed: number;
  dedup_skipped: number;
  errors: Array<{ file: string; error: string }>;
}

export interface EmbeddingJob {
  observation_ids: number[];
  model: string;
  batch_size: number;
}

export interface EmbeddingResult {
  observation_id: number;
  embedding: number[];
  model: string;
  processed_at_epoch: number;
}
