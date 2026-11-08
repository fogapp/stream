import type { Ref } from "@/types/core";
import type { ProfileInfo } from "@/types/profiles";
import type { MediaFileState } from "@/types/libraries";
import type { Chapter, PlayableKind, PlaybackMethod } from "@/types/playback";
import type { MatchState, ShowFolder } from "@/types/transcoders";

// Viewing surface (app/serializers/catalog_serializer.rb, artwork_serializer.rb).

export const ARTWORK_KINDS = ["poster", "backdrop", "logo", "still", "profile", "thumb"] as const;

export type ArtworkKind = (typeof ARTWORK_KINDS)[number];

export interface ImageInfo {
  src: string;
  srcset: string;
  width: number | null;
  height: number | null;
  placeholder: string | null;
  color: string | null;
}

export type Images = Partial<Record<ArtworkKind, ImageInfo>>;

export interface MovieCard {
  kind: "movie";
  id: string;
  title: string;
  year: number | null;
  content_rating: string | null;
  runtime_minutes: number | null;
  images: Images;
  progress: number | null;
  watched: boolean;
  tmdb_id: number | null;
  imdb_id: string | null;
  /** On a person's page: "as Neil McCauley", "Director". */
  credit?: string | null;
}

/** Where a letter's first title sits in an A–Z grid ("#" for anything not A–Z). */
export interface LetterStart {
  letter: string;
  index: number;
}

export interface ShowCard {
  kind: "show";
  id: string;
  title: string;
  year: number | null;
  content_rating: string | null;
  images: Images;
  unwatched_count: number;
  tmdb_id: number | null;
  tvdb_id: number | null;
  imdb_id: string | null;
  /** In Recently added: what arrived, e.g. "4 new episodes". */
  arrival?: string;
  /** In Recently added: the one season a batch came in, which the card opens on. */
  season_number?: number | null;
  credit?: string | null;
}

export interface EpisodeCard {
  kind: "episode";
  id: string;
  code: string;
  title: string | null;
  season_number: number;
  episode_number: number | null;
  show: { id: string; title: string; images: Images } | null;
  images: Images;
  progress: number | null;
  watched: boolean;
}

export const CREDIT_ROLES = ["cast", "director", "writer", "creator"] as const;

export type CreditRole = (typeof CREDIT_ROLES)[number];

export interface CastMember {
  person_id: string;
  name: string;
  role: CreditRole;
  character: string | null;
  job: string | null;
  image: ImageInfo | null;
}

export const EXTRA_KINDS = ["trailer", "featurette", "behind_the_scenes", "deleted_scene", "interview", "scene", "short", "other"] as const;

export type ExtraKind = (typeof EXTRA_KINDS)[number];

export interface ExtraCard {
  kind: "extra";
  id: string;
  extra_kind: ExtraKind;
  kind_label: string;
  title: string;
  duration_seconds: number | null;
  images: Images;
  /** Set when it belongs to a season rather than the whole show. */
  season_number: number | null;
}

export interface Version {
  media_file_id: string;
  /** "Director's Cut", "4K HDR"… */
  edition: string | null;
  filename: string;
  size: number;
  duration_seconds: number | null;
  video: string | null;
  audio: string | null;
  subtitles: number;
  playable: boolean;
  unplayable_reason: string | null;
}

export interface MovieDetail extends MovieCard {
  trailer: TrailerInfo | null;
  original_title: string | null;
  tagline: string | null;
  overview: string | null;
  genres: string[];
  release_date: string | null;
  vote_average: number | null;
  collection: string | null;
  library: Ref;
  match_state: MatchState;
  tmdb_id: number | null;
  imdb_id: string | null;
  resume_at: number | null;
  play_count: number;
  versions: Version[];
  cast: CastMember[];
  extras: ExtraCard[];
  collections: CollectionRef[];
  locked_fields: string[];
  /** This profile's stars, out of 10. */
  my_rating: number | null;
}

export interface SeasonSummary {
  season_number: number;
  title: string;
  episode_count: number | null;
  available_count: number;
  watched_count: number;
  images: Images;
}

export interface NextUp {
  episode_id: string;
  code: string;
  title: string | null;
  resume_at: number | null;
  started_show: boolean;
}

export interface ShowDetail extends ShowCard {
  trailer: TrailerInfo | null;
  original_title: string | null;
  overview: string | null;
  genres: string[];
  status: string | null;
  network: string | null;
  first_air_date: string | null;
  vote_average: number | null;
  library: Ref;
  match_state: MatchState;
  tmdb_id: number | null;
  seasons: SeasonSummary[];
  next_up: NextUp | null;
  cast: CastMember[];
  extras: ExtraCard[];
  collections: CollectionRef[];
  locked_fields: string[];
  /** This profile's stars, out of 10. */
  my_rating: number | null;
}

export interface SeasonEpisode extends EpisodeCard {
  locked_fields: string[];
  overview: string | null;
  air_date: string | null;
  runtime_minutes: number | null;
  available: boolean;
  resume_at: number | null;
  my_rating: number | null;
  /** More than one file: which to play. Empty with one. */
  versions: Version[];
  /** Every file behind it, whatever its state: only for an admin (Info). */
  files?: EpisodeFile[];
}

export interface EpisodeFile {
  id: string;
  path: string;
  state: MediaFileState;
  edition: string | null;
}

/** The raw record behind a show, for an admin working out why it looks as it does. */
export interface ShowInfo {
  id: string;
  title: string;
  original_title: string | null;
  sort_title: string | null;
  year: number | null;
  status: string | null;
  created_at: string;
  updated_at: string;
  metadata_refreshed_at: string | null;
  library: { id: string | null; name: string | null; roots: string[] };
  folder: string;
  folder_paths: string[];
  folders: ShowFolder[];
  ids: { tmdb_id: number | null; tvdb_id: number | null; imdb_id: string | null };
  match: { state: MatchState; score: number | null; summary: string | null };
  counts: { seasons: number; episodes: number; files: number; missing_files: number };
  directories: { path: string; files: number }[];
  files: {
    id: string;
    path: string;
    size: number;
    state: MediaFileState;
    missing_since: string | null;
    episode: { id: string; code: string; season_number: number };
  }[];
  look_alikes: {
    id: string;
    title: string;
    year: number | null;
    folder: string;
    library: string | null;
    tmdb_id: number | null;
    match_state: MatchState;
  }[];
}

export interface SeasonDetail {
  season_number: number;
  title: string;
  overview: string | null;
  episodes: SeasonEpisode[];
}

export interface PlaylistCard {
  id: string;
  title: string;
  item_count: number;
  from_plex: boolean;
  /** The playlist every profile has. */
  watch_later: boolean;
  image: ImageInfo | null;
  first: { kind: "movie" | "episode" | "video"; id: string } | null;
}

export interface PlaylistDetail extends PlaylistCard {
  pinned_to_home: boolean;
  items: (MovieCard | EpisodeCard | VideoCard)[];
}

/** Changes whenever a file becomes playable, is replaced or goes missing (`CatalogVersionSerializer`). */
export interface CatalogVersion {
  version: string;
}

/** A profile's arrangement of the web sidebar (`SidebarSerializer`). */
export interface SidebarLayout {
  order: string[];
  hidden: string[];
}

export interface CurrentProfile {
  profile: ProfileInfo;
  chosen: boolean;
  device_default_id: string | null;
  needs_picker: boolean;
}

export interface NotificationPreferences {
  ntfy_topic: string | null;
  notify_new_episodes: boolean;
  notify_subscriptions: boolean;
  ntfy_configured: boolean;
}

export interface NowPlayingSession {
  id: string;
  title: string;
  subtitle: string | null;
  back_path: string;
  profile: { id: string; name: string; color: string; avatar: string | null } | null;
  device: string | null;
  method: PlaybackMethod;
  summary: string | null;
  position_seconds: number;
  duration_seconds: number | null;
  progress: number | null;
  bitrate_kbps: number | null;
  /** Averaged from the bytes actually sent, rather than the file's own rate. */
  bitrate_measured: boolean;
  bytes_sent: number;
  started_at: string;
  last_seen_at: string;
  watched_seconds: number;
}

export interface WatchSummary {
  days: number;
  plays: number;
  hours: number;
  bytes_sent: number;
  by_profile: { name: string | null; color: string | null; plays: number; hours: number; bytes_sent: number }[];
  by_library: { name: string; plays: number; hours: number }[];
  by_day: { date: string; plays: number; hours: number }[];
  most_watched: { title: string; plays: number; hours: number }[];
}

export interface HomeHero {
  kind: "movie" | "show";
  id: string;
  title: string;
  subtitle: string | null;
  /** "Continue watching", "Next up", "Just added", "Season 2 added"… */
  label: string;
  overview: string | null;
  images: Images;
  play: { kind: PlayableKind; id: string };
  progress: number | null;
  resume_at: number | null;
  trailer: TrailerInfo | null;
}

/** Api::V1::ArtworkChoicesController#index. */
export interface ArtworkChoices {
  current: (ImageInfo & { source: string; path: string | null }) | null;
  locked: boolean;
  choices: { path: string; preview: string; width: number; height: number; language: string | null; votes: number }[];
}

/** A title's trailer, fetched into Stream's storage (Trailers.json). */
export interface TrailerInfo {
  url: string;
  name: string | null;
}

export interface VideoCard {
  kind: "video";
  id: string;
  title: string;
  upload_date: string | null;
  duration_seconds: number | null;
  channel: { id: string; title: string; avatar: ImageInfo | null } | null;
  images: Images;
  progress: number | null;
  watched: boolean;
}

export interface ChannelCard {
  kind: "channel";
  id: string;
  title: string;
  handle: string | null;
  avatar: ImageInfo | null;
  banner: ImageInfo | null;
  video_count: number;
  unwatched_count: number;
  latest_upload: string | null;
}

/** A row of a channels library's list: a card, and what its "…" acts on. */
export interface ChannelListItem extends ChannelCard {
  subscribed: boolean;
  /** Whether new uploads are fetched from YouTube (an admin's "Follow"). */
  tracked: boolean;
  url: string | null;
  youtube_id: string | null;
}

export const BACKFILLS = ["recent", "all", "since"] as const;

export type Backfill = (typeof BACKFILLS)[number];

export const YOUTUBE_DOWNLOAD_STATES = ["queued", "downloading", "done", "skipped", "failed", "removed"] as const;

export type YoutubeDownloadState = (typeof YOUTUBE_DOWNLOAD_STATES)[number];

export interface TrackingRules {
  backfill: Backfill;
  backfill_count: number;
  backfill_since: string | null;
  keep_last: number | null;
  skip_shorts: boolean;
  skip_live: boolean;
  /** A pattern (ignoring case) a title must match to be fetched; null fetches everything. */
  title_filter: string | null;
  max_height: number;
  poll_every_hours: number;
}

export interface ChannelTracking extends TrackingRules {
  tracked: boolean;
  youtube_id: string | null;
  last_polled_at: string | null;
  last_poll_error: string | null;
  downloads: Record<YoutubeDownloadState, number>;
  recent: YoutubeDownloadRow[];
}

export interface YoutubeDownloadRow {
  id: string;
  youtube_id: string;
  title: string | null;
  state: YoutubeDownloadState;
  /** Marked to keep: the channel's keep-last rule passes it by. */
  kept: boolean;
  reason: string | null;
  last_error: string | null;
  attempts: number;
  bytes: number | null;
  created_at: string;
  started_at: string | null;
  finished_at: string | null;
}

export interface YoutubeStatus {
  yt_dlp_version: string | null;
  libraries: { id: string; name: string; roots: string[]; download_root: string | null; sponsorblock: boolean }[];
  tracked: { id: string; title: string; last_polled_at: string | null; last_poll_error: string | null }[];
  downloads: Record<YoutubeDownloadState, number>;
  /** Whether a finished video offers more to watch over its last frame. */
  end_screen: boolean;
}

export interface YoutubePreview {
  kind: "channel" | "video" | "playlist";
  url: string;
  title: string | null;
  channel: {
    youtube_id: string;
    title: string;
    handle: string | null;
    description: string | null;
    avatar_url: string | null;
    banner_url: string | null;
    tracked: boolean;
  } | null;
  videos: { id: string; title: string | null; channel_id: string | null }[];
}

export interface SubscriptionsFeed {
  channels: ChannelCard[];
  videos: VideoCard[];
}

export interface ChannelDetail extends ChannelCard {
  subscribed: boolean;
  description: string | null;
  url: string | null;
  youtube_id: string | null;
  library: Ref;
  videos: VideoCard[];
}

/** Video::Identity: which YouTube video a video is (Youtube::Identifier). */
export const VIDEO_IDENTITIES = ["unchecked", "identified", "needs_review", "not_found", "not_on_youtube"] as const;

export type VideoIdentity = (typeof VIDEO_IDENTITIES)[number];

/** A YouTube video a hand-placed video might be, with why (Youtube::Identifier). */
export interface YoutubeCandidate {
  youtube_id: string;
  title: string;
  duration_seconds: number | null;
  score: number;
  reasons: string[];
}

export interface VideoDetail extends VideoCard {
  description: string | null;
  tags: string[];
  url: string | null;
  youtube_id: string | null;
  source: "info_json" | "nfo" | "tags" | "folder" | "youtube";
  identity: VideoIdentity;
  /** The closest few, while the video is still unidentified; empty once it is. */
  youtube_candidates: YoutubeCandidate[];
  chapters: Chapter[];
  playable: boolean;
  resume_at: number | null;
  more_from_channel: VideoCard[];
  /** Other videos about the same things (tags, words), from any channel. */
  related: VideoCard[];
  /** Offered over the last frame: one more from the channel, a few from others. null when Settings › YouTube turns it off. */
  end_screen: { next: VideoCard | null; others: VideoCard[] } | null;
  /** For an admin, when the channel's keep-last rule could remove it: whether it's marked to keep. */
  retention: { download_id: string; kept: boolean; keep_last: number | null } | null;
}

/** Api::V1::ClipsController#places: a place clips were taken, about a kilometre across. */
export interface ClipPlace {
  latitude: number;
  longitude: number;
  count: number;
  city: string | null;
  country: string | null;
  clips: ClipCard[];
}

export interface ClipCard {
  kind: "clip";
  id: string;
  title: string;
  captured_at: string;
  /** A camera's wall clock (show as-is), not an instant (show in the viewer's zone). */
  captured_floating: boolean;
  city: string | null;
  country: string | null;
  favorite: boolean;
  duration_seconds: number | null;
  images: Images;
  progress: number | null;
  watched: boolean;
}

export interface ClipsPage {
  years: { year: number; count: number }[];
  clips: ClipCard[];
  more: boolean;
}

export interface ClipDetail extends ClipCard {
  description: string | null;
  latitude: number | null;
  longitude: number | null;
  captured_source: "immich" | "metadata" | "filename" | "file_date";
  library: Ref;
  albums: { id: string; title: string }[];
  people: { id: string; name: string }[];
  resume_at: number | null;
  same_day: ClipCard[];
}

export type HomeHub =
  | { key: string; title: string; kind: "continue"; items: (MovieCard | EpisodeCard | VideoCard)[] }
  /** A show stands in Recently added for a batch of its episodes. */
  | { key: string; title: string; kind: "wide"; items: (MovieCard | ShowCard | EpisodeCard | VideoCard)[] }
  | { key: string; title: string; kind: "videos"; items: VideoCard[] }
  | { key: string; title: string; kind: "clips"; items: ClipCard[] }
  | { key: string; title: string; kind: "poster"; items: (MovieCard | ShowCard)[] };

export interface HomeHubs {
  profile: { id: string; name: string; color: string };
  /** One of `heroes`, chosen at random by the server. */
  hero: HomeHero | null;
  /** What may take the top of the page: Continue watching, Next up, new films and shows. */
  heroes: HomeHero[];
  hubs: HomeHub[];
  /** Every hub in this profile's order, shown or not: what Customize edits. */
  layout: { key: string; title: string; hidden: boolean }[];
}

export type CollectionKind = "tmdb" | "manual" | "smart";

export interface SmartRules {
  kinds: ("movie" | "show")[];
  library_ids: string[];
  genres: string[];
  year_from?: number | null;
  year_to?: number | null;
  min_rating?: number | null;
  added_within_days?: number | null;
  unwatched: boolean;
  uhd: boolean;
  hdr: boolean;
  sort: "added" | "title" | "year" | "rating";
  limit: number;
}

export interface CollectionCard {
  kind: "collection";
  id: string;
  title: string;
  collection_kind: CollectionKind;
  /** One library's, or (null) the household's. */
  library: Ref | null;
  item_count: number;
  images: Images;
}

/** A film of a TMDB collection that no library has: shown faded, to complete the series. */
export interface MissingPart {
  tmdb_id: number;
  title: string;
  year: number | null;
  release_date: string | null;
  overview: string | null;
  images: Images;
}

export interface CollectionDetail extends CollectionCard {
  pinned_to_home: boolean;
  /** A TMDB collection's films nobody has, in release order (none for a restricted profile). */
  missing: MissingPart[];
  overview: string | null;
  locked_fields: string[];
  rules: SmartRules | null;
  items: (MovieCard | ShowCard)[];
}

/** A collection a title is in, on the title's page. */
export interface CollectionRef {
  id: string;
  title: string;
  kind: CollectionKind;
}

export interface SearchPerson {
  id: string;
  name: string;
  image: ImageInfo | null;
}

export interface SearchResults {
  movies: MovieCard[];
  shows: ShowCard[];
  episodes: EpisodeCard[];
  people: SearchPerson[];
  collections: { id: string; title: string; image: ImageInfo | null }[];
  channels: { id: string; title: string; image: ImageInfo | null }[];
  videos: VideoCard[];
  /** Transcript hits: where it was said, and the words around it (the match in << >>). */
  said: { kind: PlayableKind; id: string; title: string; start: number; snippet: string }[];
  clips: ClipCard[];
}

/** What the palette searches Hook for (Hook::Requests::Kind). */
export const HOOK_REQUEST_KINDS = ["movie", "show"] as const;

export type HookRequestKind = (typeof HOOK_REQUEST_KINDS)[number];

/** What following a show keeps coming (Hook::Requests::Follow). */
export const HOOK_FOLLOWS = ["future", "everything"] as const;

export type HookFollow = (typeof HOOK_FOLLOWS)[number];

/** Whether the palette offers Hook to this person (GET /hook). */
export interface HookAvailability {
  available: boolean;
}

/** A film or show found through Hook (HookRequestSerializer.hit_json). */
export interface HookHit {
  kind: HookRequestKind;
  provider: string;
  external_id: string;
  title: string;
  year: number | null;
  overview: string | null;
  poster_url: string | null;
  network: string | null;
  /** In Stream, and this profile may see it. */
  in_stream_id: string | null;
  /** A film already wanted in Hook. */
  requested: boolean;
  hook_show_id: string | null;
}

/** A film asked for (POST /hook/movies): Hook's want status and why. */
export interface HookWant {
  status: string;
  explain: string | null;
}

/** One of a show's seasons, counted against Stream (HookRequestSerializer.show_json). */
export interface HookSeason {
  number: number;
  episodes: number;
  aired: number;
  in_stream: number;
  requested: number;
  next_air_date: string | null;
}

export interface HookShow {
  hook_show_id: string;
  title: string;
  year: number | null;
  poster_url: string | null;
  network: string | null;
  in_stream_id: string | null;
  /** The follow's rule in words, when Hook follows the show. */
  following: string | null;
  seasons: HookSeason[];
}

/** What asking for a show's seasons did (POST /hook/shows/:id/want). */
export interface HookShowAsked {
  created: number;
  already: number;
  show: HookShow;
}

export interface ClipFilters {
  albums: { id: string; title: string; count: number }[];
  people: { id: string; name: string; count: number; image: ImageInfo | null }[];
  favorites: number;
}

export interface TranscriptInfo {
  available: boolean;
  source?: "subtitles" | "whisper";
  language?: string | null;
  lines: { start: number; end: number; text: string }[];
}

export interface PersonDetail extends SearchPerson {
  tmdb_id: number;
  movies: MovieCard[];
  shows: ShowCard[];
}
