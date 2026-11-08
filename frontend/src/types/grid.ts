import type { Images } from "@/types/catalog";

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
  /** Leave out what's been finished: by any profile, or by any of `unwatched_profile_ids`. */
  unwatched?: boolean;
  unwatched_profile_ids?: string[];
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
  /** Whose watching an unwatched block counts. */
  profiles: { id: string; name: string }[];
  /** Cameras and web streams a channel can show instead (PROPOSAL §7.8); `mlb_team`: a club's MLB.tv games. */
  live_streams: { id: string; name: string; mlb_team: boolean }[];
  /** The clubs a channel can carry the games of; empty without an MLB.tv account. */
  mlb_teams: { id: number; name: string }[];
  decades: { value: number; count: number }[];
  time_zone: string;
}

export const PRESET_KINDS = ["network", "kids", "sitcoms", "decade", "movies", "one_show", "holiday", "youtube"] as const;

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
