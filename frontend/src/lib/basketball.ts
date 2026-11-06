import type { BasketballDay, BasketballGame, BasketballGameState } from "@/types";

/** The order Basketball shows a day's games in, and what each group is called. */
export const BASKETBALL_STATE_ORDER: readonly BasketballGameState[] = ["live", "upcoming", "final", "off"];

export const BASKETBALL_STATE_LABELS: Record<BasketballGameState, string> = {
  live: "Live",
  upcoming: "Upcoming",
  final: "Final",
  off: "Not played",
};

/** What a game's NBA.com link says: League Pass plays a game live, and its replay after. */
export const BASKETBALL_WATCH_LABELS: Record<BasketballGameState, string | null> = {
  live: "Watch on NBA.com",
  upcoming: "Watch on NBA.com",
  final: "Replay on NBA.com",
  off: null,
};

/** A line score's column: 1–4, then OT, 2OT… */
export function periodLabel(period: number): string {
  if (period <= 4) return String(period);
  return period === 5 ? "OT" : `${period - 4}OT`;
}

/** When it starts, in the browser's time: "7:30 PM", or TBD. */
export function startTime(game: BasketballGame): string {
  if (game.start_time_tbd) return "TBD";
  return new Date(game.starts_at).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}

/** A day's games grouped as Basketball shows them, empty groups left out. */
export function groupGames(games: BasketballGame[]): { state: BasketballGameState; games: BasketballGame[] }[] {
  return BASKETBALL_STATE_ORDER.map((state) => ({ state, games: games.filter((game) => game.state === state) })).filter(
    (group) => group.games.length > 0,
  );
}

/** How often to ask again: every few seconds while a game is on, now and then on today's, never on a day that's settled. */
export function refreshEvery(day: BasketballDay | undefined): number | false {
  if (!day) return false;
  if (day.games.some((game) => game.state === "live")) return 15_000;
  return day.date === day.today ? 60_000 : false;
}
