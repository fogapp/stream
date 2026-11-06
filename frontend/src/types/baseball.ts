import type { MovieCard, SearchPerson, ShowCard } from "@/types/catalog";
import type { Testable } from "@/types/core";

// Baseball (app/serializers/baseball_serializer.rb, PROPOSAL §7.8).

/** GET /baseball: whether the household has an MLB.tv account, so whether Baseball is in the sidebar. */
export interface BaseballAvailability {
  available: boolean;
}

export const BASEBALL_GAME_STATES = ["upcoming", "live", "final", "off"] as const;

/** off: postponed, suspended or cancelled. */
export type BaseballGameState = (typeof BASEBALL_GAME_STATES)[number];

export const BASEBALL_SIDES = ["away", "home"] as const;

export type BaseballSide = (typeof BASEBALL_SIDES)[number];

export interface BaseballTeam {
  id: number;
  name: string;
  club: string;
  location: string;
  abbreviation: string;
  /** MLB's own, from its CDN, as TMDB's posters are. */
  logo_url: string;
  /** The same logo as a PNG, for clients that can't draw SVG (the Apple TV). */
  logo_png_url: string;
}

export interface BaseballGameSide {
  team: BaseballTeam;
  /** "92-70"; in the postseason, the series so far. */
  record: string | null;
  score: number | null;
  hits: number | null;
  errors: number | null;
  winner: boolean;
  probable_pitcher: string | null;
}

export interface BaseballInning {
  number: number;
  ordinal: string;
  /** top, middle, bottom or end. */
  half: string;
  outs: number;
  balls: number;
  strikes: number;
  bases: { first: boolean; second: boolean; third: boolean };
}

export interface BaseballGame {
  /** MLB's gamePk. */
  id: number;
  starts_at: string;
  start_time_tbd: boolean;
  state: BaseballGameState;
  /** MLB's own words: "In Progress", "Warmup", "Postponed: Rain". */
  status: string;
  /** On MLB.tv now, or in its warm-up. */
  watchable: boolean;
  venue: string | null;
  /** Postseason and the like: "ALCS Game 6", "TB leads 3-2". */
  series: { name: string | null; status: string | null } | null;
  /** Game 1 or 2 of a doubleheader. */
  double_header: number | null;
  /** While it's on. */
  inning: BaseballInning | null;
  innings: { number: number; away: number | null; home: number | null }[];
  scheduled_innings: number;
  away: BaseballGameSide;
  home: BaseballGameSide;
  /** TV, in English: whose broadcast it is, and its channel. */
  broadcasts: { name: string; side: BaseballSide | "national" }[];
  decisions: { winner: string | null; loser: string | null; save: string | null } | null;
}

/** GET /baseball/games?date=. */
export interface BaseballDay {
  date: string;
  today: string;
  /** The nearest days either side with games. */
  previous_date: string | null;
  next_date: string | null;
  games: BaseballGame[];
}

/** POST /baseball/games/:id/watch: the team's stream that plays it. */
export interface BaseballWatch {
  live_stream_id: string;
  name: string;
}

export type OpenSubtitlesSettings =
  | { configured: false }
  | ({
      configured: true;
      username: string | null;
      languages: string[];
      enabled: boolean;
      remaining_downloads: number | null;
      resets_at: string | null;
    } & Testable);

export type TraktSettings =
  | { configured: false }
  | ({
      configured: true;
      client_id: string;
    } & Testable);

export const TRAKT_LINK_STATES = ["pending", "linked", "needs_relink"] as const;

export type TraktLinkState = (typeof TRAKT_LINK_STATES)[number];

export interface TraktLink {
  state: TraktLinkState;
  username: string | null;
  linked_at: string | null;
  last_synced_at: string | null;
  last_error: string | null;
  last_error_at: string | null;
  user_code: string | null;
  verification_url: string | null;
  code_expires_at: string | null;
  poll_interval: number | null;
}

export interface TraktAccountInfo {
  available: boolean;
  account: TraktLink | null;
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

/** How a live stream's relay is going (Playback::LiveCache status). */
export const LIVE_RELAY_STATES = ["starting", "live", "reconnecting"] as const;

export type LiveRelayState = (typeof LIVE_RELAY_STATES)[number];
