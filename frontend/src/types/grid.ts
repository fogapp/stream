import { OPTIMIZED_STATES } from "@/types/optimized";
import type { ImageInfo, Images } from "@/types/catalog";
import type { JobRunStatus, Ref, Testable } from "@/types/core";
import type { OptimizedVersion } from "@/types/optimized";
import type { PlaybackTab } from "@/types/playback";

export interface Station {
  id: string;
  number: string;
  name: string;
  call_sign: string | null;
  hidden: boolean;
  favorite: boolean;
  /** Shows this camera or web stream instead of programming (PROPOSAL §7.8). */
  live_stream_id: string | null;
}

export const STATION_LAYERS = ["base", "daypart", "appointment", "special"] as const;

export type StationLayer = (typeof STATION_LAYERS)[number];

export const STATION_ORDERINGS = ["shuffle", "sequential", "rotate", "marathon", "chronological"] as const;

export type StationOrdering = (typeof STATION_ORDERINGS)[number];

export const STATION_SOURCE_KINDS = ["movie", "episode", "video"] as const;

export type StationSourceKind = (typeof STATION_SOURCE_KINDS)[number];

/** What a block draws from (app/services/stations/rules.rb); absent keys mean "any". */
export interface StationSource {
  kinds?: StationSourceKind[];
  show_ids?: string[];
  exclude_show_ids?: string[];
  movie_ids?: string[];
  exclude_movie_ids?: string[];
  collection_ids?: string[];
  /** YouTube channels whose videos a block draws from (with the "video" kind). */
  channel_ids?: string[];
  library_ids?: string[];
  person_ids?: string[];
  genres?: string[];
  exclude_genres?: string[];
  networks?: string[];
  studios?: string[];
  keywords?: string[];
  exclude_keywords?: string[];
  year_from?: number | null;
  year_to?: number | null;
  min_rating?: number | null;
  max_rating_age?: number | null;
  allow_unrated?: boolean;
  min_minutes?: number | null;
  max_minutes?: number | null;
  include_specials?: boolean;
}

export interface StationBlock {
  id?: string;
  layer: StationLayer;
  name: string | null;
  label?: string;
  /** Monday is bit 0, Sunday bit 6. */
  days: number;
  start_minute: number | null;
  end_minute: number | null;
  starts_on: string | null;
  ends_on: string | null;
  source: StationSource;
  ordering: StationOrdering;
  marathon_length: number;
  loops: boolean;
}

export const STATION_FILLERS = ["slate", "extras", "videos"] as const;

export type StationFiller = (typeof STATION_FILLERS)[number];

export interface StationConfig extends Station {
  snap_minutes: number;
  no_repeat_days: number;
  filler: StationFiller;
  filler_channel_ids: string[];
  /** Break programs at their chapters for filler. */
  breaks: boolean;
  /** MLB clubs whose games air whenever they play, over the programming; the first listed first. */
  mlb_team_ids: number[];
  scheduled_through: string | null;
  last_scheduled_at: string | null;
  last_error: string | null;
  blocks: StationBlock[];
}

export interface StationOptions {
  genres: { value: string; count: number }[];
  networks: { value: string; count: number }[];
  studios: { value: string; count: number }[];
  keywords: { value: string; count: number }[];
  shows: { id: string; title: string; year: number | null }[];
  collections: { id: string; title: string }[];
  youtube_channels: { id: string; title: string }[];
  /** Cameras and web streams a channel can show instead (PROPOSAL §7.8); `mlb_team`: a club's MLB.tv games. */
  live_streams: { id: string; name: string; mlb_team: boolean }[];
  /** The clubs a channel can carry the games of; empty without an MLB.tv account. */
  mlb_teams: { id: number; name: string }[];
  decades: { value: number; count: number }[];
  time_zone: string;
}

export const PRESET_KINDS = ["network", "kids", "sitcoms", "decade", "movies", "one_show", "holiday"] as const;

export type PresetKind = (typeof PRESET_KINDS)[number];

/** A ready-made channel as a draft (app/services/stations/presets.rb). */
export interface StationPresetDraft {
  number: string;
  name: string;
  call_sign: string | null;
  snap_minutes: number;
  no_repeat_days: number;
  filler: StationFiller;
  filler_channel_ids: string[];
  /** Break programs at their chapters for filler. */
  breaks: boolean;
  blocks: StationBlock[];
  description: string;
}

export interface StationPreview {
  airings: (Airing & { block_index: number | null })[];
  warnings: { tone: "info" | "warning" | "danger"; text: string }[];
}

export interface Airing {
  id: string;
  station_id: string;
  starts_at: string;
  ends_at: string;
  reason: string;
  /** Between programs: a trailer or a video, not a program in the guide. */
  filler: boolean;
  /** Where in the file this airing runs: a program broken for breaks airs in parts. */
  media_start: number;
  media_end: number | null;
  /** live_stream: a channel showing a camera or web stream (PROPOSAL §7.8), the stream all day. */
  kind: "movie" | "episode" | "extra" | "video" | "live_stream";
  playable_id: string;
  /** The show's title for an episode. */
  title: string;
  subtitle: string | null;
  episode_title: string | null;
  code: string | null;
  show_id: string | null;
  /** The YouTube channel of a video. */
  channel_id: string | null;
  year: number | null;
  content_rating: string | null;
  overview: string | null;
  images: Images;
  /** This profile asked to be reminded before it starts. */
  reminded: boolean;
}

export interface GuideStation extends Station {
  airings: Airing[];
}

export interface Guide {
  now: string;
  from: string;
  to: string;
  time_zone: string;
  stations: GuideStation[];
}

export interface PathMappingInfo {
  id: string;
  remote_prefix: string;
  local_prefix: string;
}

/** Settings › Integrations › Sonarr & Radarr (ArrWebhooksController#json_for). */
export interface ArrWebhookSettings {
  url: string;
  last_received_at: string | null;
  last_source: string | null;
  last_event: string | null;
  last_outcome: string | null;
  path_mappings: PathMappingInfo[];
}

/** Profile::Kind: a kid profile has no settings, admin pages or activity. */
export const PROFILE_KINDS = ["standard", "kid"] as const;

export type ProfileKind = (typeof PROFILE_KINDS)[number];

export interface ProfileInfo {
  id: string;
  name: string;
  color: string;
  /** An emoji, or null for the name's initial. */
  avatar: string | null;
  has_pin: boolean;
  kind: ProfileKind;
  max_rating_age: number | null;
  allow_unrated: boolean;
  library_ids: string[];
  curated: boolean;
  up_next_seconds: number | null;
  always_skip_intro: boolean;
  always_skip_credits: boolean;
  still_watching_after: number | null;
  /** A video starts as its page opens, replacing what's playing (muted if the browser insists). */
  autoplay_videos: boolean;
}

/** What a profile can hide from itself (ProfileExclusion::EXCLUDABLE). */
export const HIDEABLE_KINDS = ["movie", "show", "channel"] as const;

export type HideableKind = (typeof HIDEABLE_KINDS)[number];

/** A title a profile's own configuration names (ProfileContentSerializer). */
export interface ProfileContentItem {
  kind: HideableKind | "album";
  id: string;
  title: string;
  /** A film's or show's year, a channel's handle. */
  detail: string | null;
  image: ImageInfo | null;
}

/** GET /profiles/:id/content: hidden from it, and (admins only) tagged for it. */
export interface ProfileContent {
  hidden: ProfileContentItem[];
  tagged?: ProfileContentItem[];
}

export interface PlexUserMappingInfo {
  id: string;
  plex_name: string;
  plex_admin: boolean;
  profile_id: string | null;
}

/** Settings › Import from Plex (PlexSerializer.connection_json). Never the token. */
export type PlexConnectionInfo =
  | { connected: false }
  | ({
      connected: true;
      server_url: string;
      server_name: string | null;
      sync_enabled: boolean;
      last_synced_at: string | null;
      users: PlexUserMappingInfo[];
    } & Testable);

export interface PlexImportRun {
  id: string;
  dry_run: boolean;
  status: JobRunStatus;
  counts: Record<string, number>;
  unmatched: { kind: "movie" | "episode"; title: string }[];
  users: ({ plex_name: string; profile: string | null; error?: string } & Record<string, unknown>)[];
  error: string | null;
  started_at: string | null;
  finished_at: string | null;
  created_at: string;
}

/** A page of a console data table (BaseController#paged). */
export interface Page<T> {
  rows: T[];
  total: number;
  /** The total stopped counting at its ceiling: there are at least this many. */
  total_capped: boolean;
  page: number;
  per: number;
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
