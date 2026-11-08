import { OPTIMIZED_STATES } from "@/types/optimized";
import type { ImageInfo } from "@/types/catalog";
import type { Page, Ref } from "@/types/core";
import type { OptimizedVersion } from "@/types/optimized";
import type { LiveStreamKind } from "@/types/live";
import type { EncoderKind } from "@/types/transcoders";

export const SPONSOR_CATEGORIES = ["sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "filler", "music_offtopic"] as const;

export type SponsorCategory = (typeof SPONSOR_CATEGORIES)[number];

export const SPONSOR_ACTIONS = ["skip", "ask", "show"] as const;

export type SponsorAction = (typeof SPONSOR_ACTIONS)[number];

export interface SponsorSegmentInfo {
  category: SponsorCategory;
  start: number;
  end: number;
  action: SponsorAction;
}

/** What Up next offers: the next episode, or a playlist's next movie or episode. */
export interface NextItem {
  kind: "episode" | "movie" | "video";
  id: string;
  code: string | null;
  title: string | null;
  show_title: string | null;
  image: ImageInfo | null;
  playlist_id: string | null;
}

export const PLAYABLE_KINDS = ["movie", "episode", "extra", "video", "clip"] as const;

export type PlayableKind = (typeof PLAYABLE_KINDS)[number];

export const PLAYBACK_METHODS = ["direct", "remux", "audio_transcode", "optimized", "video_transcode"] as const;

export type PlaybackMethod = (typeof PLAYBACK_METHODS)[number];

/** How a play failed, when it carried on a rung down (PlaybackSession::FailureClass). */
export const FAILURE_CLASSES = ["decode", "unsupported", "stalled", "network", "server"] as const;

export type FailureClass = (typeof FAILURE_CLASSES)[number];

export interface Track {
  index: number;
  codec: string | null;
  language: string | null;
  title: string | null;
  channels: number | null;
  /** Hz, for an audio track; null when the file doesn't say. */
  sample_rate: number | null;
  default: boolean;
  forced: boolean;
}

/** PlaybackSessionSerializer — what pressing Play returns. */
export interface PlaybackSessionInfo {
  id: string;
  method: PlaybackMethod;
  profile_id: string;
  title: string;
  subtitle: string | null;
  back_path: string;
  show_id?: string;
  /** An episode's season, for the Related panel. */
  season_number?: number;
  source: { kind: "file" | "hls"; url: string; mime_type: string };
  progress_url: string;
  events_url: string;
  audio_stream_index: number | null;
  subtitles: SubtitleTrack[];
  fonts: string[];
  chapters: Chapter[];
  trickplay: TrickplayInfo | null;
  markers: PlaybackMarker[];
  skip: Record<MarkerKind, boolean>;
  next_up: NextItem | null;
  /** SponsorBlock, with what this profile does about each. */
  segments: SponsorSegmentInfo[];
  /** Started from a playlist: Up next follows it. */
  playlist_id: string | null;
  up_next_seconds: number;
  still_watching_after: number;
  /** EBU R128 measurements; null until the file has been measured. */
  loudness: { integrated: number; true_peak: number } | null;
  decision: {
    summary: string;
    video: { index: number; copy: boolean; codec: string; height: number | null; tonemap: boolean } | null;
    audio: { index: number; copy: boolean; codec: string; channels: number | null } | null;
  };
  /** The file's share can't deliver it as fast as it plays, so it will keep pausing. */
  falls_behind: boolean;
  /** Carried on from a session that failed, a rung down; upgradable: worth climbing back at the next seek. */
  fallback: { from_method: PlaybackMethod; failure_class: FailureClass; upgradable: boolean } | null;
  resume_at: number;
  duration_seconds: number | null;
  /** For frame-stepping; null when the file doesn't say. */
  frame_rate: number | null;
  /** The subtitle drawn into this stream, if one is (a SubtitleTrack id). */
  burned_subtitle: string | null;
  media_file: { id: string; filename: string; audio: Track[]; subtitles: Track[] } | null;
  /** Tuned in on a Grid channel. */
  live: LiveInfo | null;
  /** A camera or web stream (PROPOSAL §7.8), relayed live. */
  live_stream: { id: string; name: string; kind: LiveStreamKind; library_id: string } | null;
}

// Grid (app/serializers/station_serializer.rb, PROPOSAL §7.7).

export interface LiveInfo {
  station_id: string;
  number: string;
  name: string;
  airing_id: string;
  starts_at: string;
  ends_at: string;
  /** The server's clock when the session was made: where "live" is. */
  server_now: string;
  /** A part of a program broken for breaks: where in the file it runs (end null: to the end). */
  media_start: number;
  media_end: number | null;
  /** What follows it on the channel, as the schedule had it then (null: nothing scheduled yet). */
  next_airing_id: string | null;
  next_starts_at: string | null;
}

export const SUBTITLE_FORMATS = ["vtt", "ass", "pgs", "burn"] as const;

export type SubtitleFormat = (typeof SUBTITLE_FORMATS)[number];

/** A subtitle the player can show (PlaybackSessionSerializer.subtitle_json). */
export interface SubtitleTrack {
  id: string;
  format: SubtitleFormat;
  language: string | null;
  title: string | null;
  forced: boolean;
  default: boolean;
  hearing_impaired: boolean;
  external: boolean;
  urls: Partial<Record<"vtt" | "ass" | "sup", string>>;
  /** DVD or DVB pictures nothing here draws: choosing it restarts the stream with it burned in. */
  burn: boolean;
  stream_index: number | null;
}

/** How a play went, worst first (PlaybackSession::Outcome). */
export const PLAYBACK_OUTCOMES = ["failed", "errored", "stalled", "clean"] as const;

export type PlaybackOutcome = (typeof PLAYBACK_OUTCOMES)[number];

/** A row of the Playback page's Sessions table (PlaybackDecisionSerializer.row_json). */
export interface PlaybackDecisionRow {
  id: string;
  title: string | null;
  started_at: string;
  ended_at: string | null;
  position_seconds: number;
  state: "active" | "ended";
  profile: Ref | null;
  device: { id: string | null; name: string | null };
  method: PlaybackMethod;
  summary: string | null;
  reasons: string[];
  fix_hint: string | null;
  transcode_error: string | null;
  media_file: { id: string; filename: string } | null;
  stalls: number;
  /** Times the player got itself going again: holes hopped, fragments fetched again, a frozen picture reloaded. */
  recoveries: number;
  errors: number;
  /** Pressing Play to the first frame, when the player timed it. */
  startup_ms: number | null;
  outcome: PlaybackOutcome;
}

/** The Playback page's tabs, which a health check links to with its filters. */
export const PLAYBACK_TABS = ["sessions", "converting", "queue", "optimized", "learned"] as const;

export type PlaybackTab = (typeof PLAYBACK_TABS)[number];

export interface PlaybackHealth {
  status: HealthStatus;
  checks: HealthCheck[];
}

/** One session in full (PlaybackDecisionSerializer.detail_json). */
export interface PlaybackDecisionDetail extends PlaybackDecisionRow {
  /** The decision's particulars: the video and audio plans, the container, a refusal. */
  decision: { video?: Record<string, unknown> | null; audio?: Record<string, unknown> | null; container?: string | null; refusal?: string | null };
  events: { kind: string; at: string; position_seconds: number | null; message: string | null }[];
}

/** Who and what has played, for the Sessions table's filters. */
export interface PlaybackFacets {
  profiles: Ref[];
  devices: Ref[];
}

export interface PlaybackSummary {
  since: string;
  total: number;
  methods: Record<PlaybackMethod, number>;
  top_reasons: { summary: string; count: number }[];
  /** Grid channel changes: how long to the first frame. */
  channel_changes: { count: number; ready: number; median_ms: number | null; p90_ms: number | null };
  /** Grid programs giving way to the next: tuned ahead (ready), noticed only by the watchdog, and how long to the next's first frame. */
  program_changes: { count: number; ready: number; watchdog: number; median_ms: number | null; p90_ms: number | null };
  /** Pressing Play to the first frame, per method. */
  startup: Record<PlaybackMethod, TimingSpread>;
  /** Seeks to somewhere not yet buffered, to the frame there. */
  seeks: TimingSpread;
  stalls: number;
  recoveries: number;
  errors: number;
  devices: { id: string; name: string; last_seen_at: string }[];
  cap: number;
  encoder: EncoderKind;
  remote_transcoders: number;
  converting_now: number;
}

export interface Chapter {
  start: number;
  end: number;
  title: string | null;
}

/** Seek-bar thumbnails: sheets of columns × rows tiles, one per `interval` seconds. */
export interface TrickplayInfo {
  sheet_url: string;
  interval: number;
  tile_width: number;
  tile_height: number;
  columns: number;
  rows: number;
  count: number;
}

export const MARKER_KINDS = ["intro", "recap", "credits"] as const;

export type MarkerKind = (typeof MARKER_KINDS)[number];

export interface PlaybackMarker {
  kind: MarkerKind;
  start: number;
  end: number;
}

/** A rung that failed for a file on a kind of client, which decisions skip until it's tried again (PlaybackLessonSerializer). */
export interface PlaybackLessonRow {
  id: string;
  media_file_id: string;
  filename: string | null;
  client_class: string;
  rung: string;
  rung_label: string;
  failures: number;
  successes: number;
  failure_class: FailureClass | null;
  cause: string | null;
  last_failed_at: string | null;
  last_succeeded_at: string | null;
  /** Still skipped: failed since it last worked, within the probation. */
  active: boolean;
  retry_at: string | null;
}

/** A health check's verdict (Playback::Health::Status). */
export const HEALTH_STATUSES = ["ok", "watch", "act"] as const;

export type HealthStatus = (typeof HEALTH_STATUSES)[number];

export const HEALTH_KEYS = ["failed_plays", "live_conversions", "startup", "optimizer", "live_streams"] as const;

export type HealthKey = (typeof HEALTH_KEYS)[number];

/** One card of the health strip (PlaybackHealthSerializer). */
export interface HealthCheck {
  key: HealthKey;
  status: HealthStatus;
  title: string;
  metric: string;
  detail: string;
  /** What to do, when there's something to do. */
  action: string | null;
  /** The tab and its filters, as the page's URL takes them — or another page's `path`. */
  link: ({ tab: PlaybackTab } & Record<string, string | number | string[]>) | { path: string };
}

/** How long something took this week: typically, and for nineteen in twenty. */
export interface TimingSpread {
  count: number;
  median_ms: number | null;
  p95_ms: number | null;
}

/** A file's optimize status in the Needs converting table: its version's state, or none. */
export const CONVERSION_STATUSES = ["none", ...OPTIMIZED_STATES] as const;

export type ConversionStatus = (typeof CONVERSION_STATUSES)[number];

/** A row of the Needs converting table (Playback::ConversionQuery). */
export interface TranscodeReportRow {
  media_file_id: string;
  filename: string;
  title: string | null;
  devices: { device: string; summary: string }[];
  /** No device seen this month plays it without converting: the hourly pass optimizes these. */
  all_devices: boolean;
  optimized: OptimizedVersion | null;
  library: Ref | null;
  size: number | null;
  duration_seconds: number | null;
  /** Times it was converted live for someone in the last 30 days, and the last. */
  conversions: number;
  last_converted_at: string | null;
  status: ConversionStatus;
}

/** The Needs converting table's page, with what its filters can offer. */
export interface TranscodeReportPage extends Page<TranscodeReportRow> {
  facets: { devices: string[]; libraries: Ref[] };
}
