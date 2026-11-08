import type { Ref } from "@/types/core";
import type { MediaFileState } from "@/types/libraries";
import type { OptimizedVersion } from "@/types/optimized";
import type { Chapter, PlaybackMarker, PlaybackMethod, SubtitleFormat } from "@/types/playback";

// Live streams (app/serializers/live_stream_serializer.rb, PROPOSAL §7.8).

export const LIVE_STREAM_KINDS = ["camera", "web", "youtube", "mlb"] as const;

export type LiveStreamKind = (typeof LIVE_STREAM_KINDS)[number];

/** Which team's TV broadcast an MLB.tv game plays. */
export const LIVE_STREAM_FEEDS = ["home", "away"] as const;

export type LiveStreamFeed = (typeof LIVE_STREAM_FEEDS)[number];

export const LIVE_STREAM_STATUSES = ["online", "offline"] as const;

export type LiveStreamStatus = (typeof LIVE_STREAM_STATUSES)[number];

export interface LiveStreamTrack {
  kind: "video" | "audio";
  codec: string | null;
  width: number | null;
  height: number | null;
  frame_rate: number | null;
  channels: number | null;
}

/** A camera, web, YouTube or MLB.tv stream. Never its address: `source` is scheme, host and port (a YouTube or MLB.tv link is its own). */
export interface LiveStream {
  id: string;
  type: "live_stream";
  name: string;
  kind: LiveStreamKind;
  /** An MLB.tv game's; null for every other kind. */
  feed: LiveStreamFeed | null;
  library_id: string;
  description: string | null;
  content_rating: string | null;
  source: string;
  status: LiveStreamStatus;
  last_seen_at: string | null;
  /** Its picture a few minutes ago at most (signed); null until one's been taken. */
  still_url: string | null;
  tracks: LiveStreamTrack[];
  /** Admins only. */
  trust_certificate?: boolean;
  /** Relayed all the time, so play starts at once. */
  keep_connected?: boolean;
  last_error?: string | null;
  last_error_at?: string | null;
  consecutive_failures?: number;
  probed_at?: string | null;
  container?: string | null;
}

/** POST /live_streams/test. */
export interface LiveStreamTestResult {
  ok: boolean;
  message: string;
  tracks?: LiveStreamTrack[];
}

/** StorageLocation::Report — a folder checked before it's saved. */
export interface PathReport {
  path: string;
  ok: boolean;
  message: string;
  exists: boolean;
  writable: boolean;
  total_bytes: number | null;
  free_bytes: number | null;
}

export const STREAM_KINDS = ["video", "audio", "subtitle", "attachment", "data"] as const;

export type StreamKind = (typeof STREAM_KINDS)[number];

export const HDR_FORMATS = ["hdr10", "hdr10_plus", "hlg", "dolby_vision"] as const;

export type HdrFormat = (typeof HDR_FORMATS)[number];

export const ANALYSIS_STEPS = [
  "probe",
  "keyframes",
  "match",
  "artwork",
  "subtitles",
  "trickplay",
  "markers",
  "loudness",
  "transcript",
  "subtitle_fetch",
  "optimize",
  "youtube_details",
] as const;

export type AnalysisStep = (typeof ANALYSIS_STEPS)[number];

export const ANALYSIS_STATUSES = ["pending", "running", "succeeded", "failed"] as const;

export type AnalysisStatus = (typeof ANALYSIS_STATUSES)[number];

export interface MediaFileSummary {
  id: string;
  library: Ref;
  path: string;
  filename: string;
  size: number;
  mtime: string;
  state: MediaFileState;
  container: string | null;
  duration_seconds: number | null;
  bit_rate: number | null;
  last_error: string | null;
  missing_since: string | null;
  probed_at: string | null;
  fingerprint: string | null;
  /** What the file is an edition of: a movie, or one or more episodes. */
  matches: MediaFileMatch[];
}

export type MediaFileMatch =
  | { type: "movie"; id: string; tmdb_id: number | null; imdb_id: string | null; edition: string | null }
  | {
      type: "episode";
      id: string;
      show_id: string;
      show_tmdb_id: number | null;
      season_number: number;
      episode_number: number | null;
    };

export interface MediaStreamInfo {
  index: number;
  kind: StreamKind;
  codec: string | null;
  profile: string | null;
  level: number | null;
  bit_depth: number | null;
  width: number | null;
  height: number | null;
  frame_rate: number | null;
  pixel_format: string | null;
  hdr_format: HdrFormat | null;
  dolby_vision_profile: number | null;
  channels: number | null;
  channel_layout: string | null;
  language: string | null;
  title: string | null;
  bit_rate: number | null;
  default: boolean;
  forced: boolean;
}

export interface AnalysisRunInfo {
  step: AnalysisStep;
  status: AnalysisStatus;
  started_at: string | null;
  finished_at: string | null;
  duration_ms: number | null;
  tool_version: string | null;
  error: string | null;
  consecutive_failures: number;
}

export interface MediaFileDetail extends MediaFileSummary {
  keyframes: { count: number | null; source: string | null };
  chapters: Chapter[];
  markers: (PlaybackMarker & { source: "chapter" | "detected" | "manual"; confidence: number })[];
  titles: { kind: "movie" | "episode"; id: string; title: string; path: string }[];
  subtitles: { id: string; format: SubtitleFormat; language: string | null; title: string | null; forced: boolean; external: boolean; codec: string }[];
  devices: { device: Ref; method: PlaybackMethod; summary: string }[];
  optimized: OptimizedVersion | null;
  streams: MediaStreamInfo[];
  analysis: AnalysisRunInfo[];
}

/** How a live stream's relay is going (Playback::LiveCache status). */
export const LIVE_RELAY_STATES = ["starting", "live", "reconnecting"] as const;

export type LiveRelayState = (typeof LIVE_RELAY_STATES)[number];
