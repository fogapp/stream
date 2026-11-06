import type { Ref, Testable } from "@/types/core";
import type { OptimizedVersionRow } from "@/types/optimized";

// Remote transcoders (app/serializers/transcode_node_serializer.rb).

export const ENCODER_KINDS = ["software", "vaapi", "videotoolbox"] as const;

export type EncoderKind = (typeof ENCODER_KINDS)[number];

export interface TranscodeNode {
  id: string;
  name: string;
  token_prefix: string;
  enabled: boolean;
  optimize: boolean;
  max_sessions: number;
  online: boolean;
  last_seen_at: string | null;
  encoder: EncoderKind | null;
  hostname: string | null;
  platform: string | null;
  ffmpeg: string | null;
  worker_version: string | null;
  tone_mapping: string;
  /** A transcoder fog provides (fog-compute/1): its pool of machines, and the room fog last said it has. */
  fog_pool: string | null;
  fog_free: { interactive: number; batch: number } | null;
  runs: { id: string; kind: "session" | "optimize"; state: "pending" | "running" | "stopping" | "exited"; title: string | null }[];
  created_at: string;
}

export interface TranscodeNodeCreated extends TranscodeNode {
  token: string;
}

export interface TranscodeNodeList {
  nodes: TranscodeNode[];
  local: { encoder: EncoderKind; cap: number };
  capacity: number;
}

/** A row of the Queue and Optimized tables (OptimizedVersionSerializer.table_json). */
export interface OptimizedVersionTableRow extends OptimizedVersionRow {
  /** Its place in line, counting the whole queue; null unless queued. */
  queue_position: number | null;
  encode_seconds: number | null;
  /** The file's last play, by anyone, any way. */
  last_played_at: string | null;
  /** Plays of this version since it was made. */
  plays_since: number;
  /** Queued only: roughly how big it'll be, and whether the budget has room for it by the time it's reached. */
  estimated_bytes: number | null;
  fits_budget: boolean | null;
}

/** What an admin can do to many optimized versions at once (Playback::OptimizeActions::Action). */
export const OPTIMIZE_ACTIONS = ["optimize", "prioritize", "skip", "unskip", "reencode", "retry", "delete"] as const;

export type OptimizeAction = (typeof OPTIMIZE_ACTIONS)[number];

/** What a bulk action did: how many changed, and why the rest didn't. */
export interface OptimizeActionResult {
  changed: number;
  unchanged: Record<string, number>;
}

/** Settings › Integrations › TMDB (TmdbSettingSerializer). Never the key. */
export interface TmdbSettings extends Testable {
  configured: boolean;
}

export const MATCH_STATES = ["matched", "needs_review", "unmatched"] as const;

export type MatchState = (typeof MATCH_STATES)[number];

export const TITLE_KINDS = ["movie", "show"] as const;

export type TitleKind = (typeof TITLE_KINDS)[number];

/** A scored provider candidate (Catalog::Scorer::Scored#to_h). */
export interface MatchCandidate {
  tmdb_id: number;
  title: string;
  year: number | null;
  overview: string | null;
  poster_path: string | null;
  /** TMDB's vote count; absent on candidates stored before it was kept. */
  vote_count?: number;
  score: number;
  reasons: string[];
}

/** A title in the Needs match queue (MatchSerializer). */
export interface MatchTitle {
  kind: TitleKind;
  id: string;
  title: string;
  year: number | null;
  library: Ref;
  folder: string | null;
  match_state: MatchState;
  match_score: number | null;
  match_summary: string | null;
  candidates: MatchCandidate[];
  tmdb_id: number | null;
  poster_path: string | null;
}

export interface ShowFolder {
  folder: string;
  paths: string[];
}

/** A show filed from more than one folder (MatchSerializer.folders_json). */
export interface MultiFolderShow {
  id: string;
  title: string;
  year: number | null;
  library: Ref;
  folders: ShowFolder[];
}
