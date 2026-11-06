// Optimized versions (app/serializers/optimized_version_serializer.rb).

export const OPTIMIZED_STATES = ["queued", "encoding", "ready", "failed", "skipped"] as const;

export type OptimizedState = (typeof OPTIMIZED_STATES)[number];

export const OPTIMIZED_ORIGINS = ["manual", "automatic"] as const;

export type OptimizedOrigin = (typeof OPTIMIZED_ORIGINS)[number];

/** Why a version is queued (OptimizedVersion::Reason). */
export const OPTIMIZED_REASONS = ["manual", "all_devices", "airing", "next_up"] as const;

export type OptimizedReason = (typeof OPTIMIZED_REASONS)[number];

export interface OptimizedVersion {
  id: string;
  media_file_id: string;
  state: OptimizedState;
  origin: OptimizedOrigin;
  run_now: boolean;
  progress: number;
  height: number | null;
  size: number | null;
  tonemapped: boolean;
  encoder: string | null;
  error: string | null;
  attempts: number;
  worker: string | null;
  started_at: string | null;
  finished_at: string | null;
  created_at: string;
  /** Null for an automatic one the hourly pass hasn't stamped yet. */
  reason: OptimizedReason | null;
  needed_at: string | null;
  /** When an admin said to do it next. */
  prioritized_at: string | null;
  /** Times an encode stopped part way, and the last reason why. */
  interruptions: number;
  interrupted_at: string | null;
  interruption: string | null;
}

export interface OptimizedVersionRow extends OptimizedVersion {
  filename: string | null;
  title: string | null;
}

/** What the optimizer is doing, or why it isn't (Playback::OptimizerStatus::State). */
export const OPTIMIZER_STATES = [
  "encoding",
  "no_transcoder",
  "paused",
  "waiting_quiet_hours",
  "over_budget",
  "busy",
  "starting",
  "idle",
] as const;

export type OptimizerState = (typeof OPTIMIZER_STATES)[number];

/** A running encode, with how fast it goes (× real time) and how long it has left. */
export interface OptimizedVersionEncoding extends OptimizedVersionRow {
  speed: number | null;
  eta_seconds: number | null;
}

/** The optimizer panel (Playback::OptimizerStatus.current). */
export interface OptimizerStatus {
  state: OptimizerState;
  message: string;
  paused: boolean;
  automatic: boolean;
  quiet_hours: { start_hour: number; end_hour: number; now: boolean; next_start_at: string | null; ends_at: string | null };
  transcoder: {
    online: boolean;
    last_seen_at: string | null;
    encoder: string | null;
    busy: boolean;
    remote_nodes: { id: string; name: string; encoder: string }[];
  };
  queue: { queued: number; run_now: number; manual: number; interrupted: number; failed: number; skipped: number; estimated_bytes: number };
  budget: { used_bytes: number; budget_bytes: number; full: boolean };
  encoding: OptimizedVersionEncoding[];
}
