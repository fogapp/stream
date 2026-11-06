// Basketball (app/serializers/basketball_serializer.rb, PROPOSAL §7.8).

/** GET /basketball: whether the household turned on NBA League Pass, so whether Basketball is in the sidebar. */
export interface BasketballAvailability {
  available: boolean;
}

export const BASKETBALL_GAME_STATES = ["upcoming", "live", "final", "off"] as const;

export type BasketballGameState = (typeof BASKETBALL_GAME_STATES)[number];

export const BASKETBALL_SIDES = ["away", "home"] as const;

export type BasketballSide = (typeof BASKETBALL_SIDES)[number];

export interface BasketballTeam {
  /** ESPN's team id. */
  id: string;
  name: string;
  club: string;
  location: string | null;
  abbreviation: string;
  /** A PNG drawn for a light background; logo_dark_url for a dark one. */
  logo_url: string | null;
  logo_dark_url: string | null;
}

export interface BasketballGameSide {
  team: BasketballTeam;
  /** "17-4". */
  record: string | null;
  /** Only once the game has started. */
  score: number | null;
  winner: boolean;
  /** The team's top scorer so far. */
  leader: { name: string; points: number } | null;
}

export interface BasketballGame {
  /** ESPN's event id. */
  id: string;
  starts_at: string;
  start_time_tbd: boolean;
  state: BasketballGameState;
  /** ESPN's own words: "5:21 - 3rd", "Halftime", "Final/OT", "10/21 - 7:00 PM EDT". */
  status: string;
  period: number;
  venue: string | null;
  preseason: boolean;
  /** In the playoffs: "East 1st Round - Game 3", "DET leads series 2-0". */
  series: { name: string | null; status: string | null } | null;
  /** Points by period; overtimes after the fourth. */
  periods: { number: number; away: number | null; home: number | null }[];
  scheduled_periods: number;
  away: BasketballGameSide;
  home: BasketballGameSide;
  /** TV: whose broadcast it is, and its channel. */
  broadcasts: { name: string; side: BasketballSide | "national" }[];
}

/** GET /basketball/games: one day of the NBA's schedule. */
export interface BasketballDay {
  date: string;
  today: string;
  /** The nearest days either side with games. */
  previous_date: string | null;
  next_date: string | null;
  /** The day's games on NBA.com, where League Pass plays them. */
  watch_url: string;
  games: BasketballGame[];
}
