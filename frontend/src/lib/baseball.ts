import type { BaseballDay, BaseballGame, BaseballGameState, BaseballInning, BaseballSide } from "@/types";

/** The order Baseball shows a day's games in, and what each group is called. */
export const BASEBALL_STATE_ORDER: readonly BaseballGameState[] = ["live", "upcoming", "final", "off"];

export const BASEBALL_STATE_LABELS: Record<BaseballGameState, string> = {
  live: "Live",
  upcoming: "Upcoming",
  final: "Final",
  off: "Not played",
};

/** A schedule date ("2026-10-18") as that day where the browser is, not UTC midnight. */
export function parseDay(date: string): Date {
  const [year, month, day] = date.split("-").map(Number);
  return new Date(year, month - 1, day);
}

/** Today, Yesterday, Tomorrow, or "Sat, Oct 18" — relative to MLB's today, not the browser's. */
export function dayLabel(date: string, today: string): string {
  const days = Math.round((parseDay(date).getTime() - parseDay(today).getTime()) / 86_400_000);
  if (days === 0) return "Today";
  if (days === -1) return "Yesterday";
  if (days === 1) return "Tomorrow";
  return parseDay(date).toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
}

const HALVES: Record<string, string> = { top: "Top", bottom: "Bot", middle: "Mid", end: "End" };

/** "Top 7th", "Mid 7th". */
export function inningLabel(inning: BaseballInning): string {
  return `${HALVES[inning.half] ?? ""} ${inning.ordinal}`.trim();
}

/** When it starts, in the browser's time: "7:08 PM", or TBD. */
export function startTime(game: BaseballGame): string {
  if (game.start_time_tbd) return "TBD";
  return new Date(game.starts_at).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}

/** "Final", or "Final/10" for extra innings. */
export function finalLabel(game: BaseballGame): string {
  return game.innings.length > game.scheduled_innings ? `Final/${game.innings.length}` : "Final";
}

export interface WatchChoice {
  side: BaseballSide;
  /** The team whose broadcast it is; null when one broadcast serves both. */
  team: string | null;
  /** Its channel, when MLB says. */
  channel: string | null;
}

/**
 * What can be watched of a game: each team's own broadcast, away first — or,
 * when there's only a national one (the postseason), that one, once.
 */
export function watchChoices(game: BaseballGame): WatchChoice[] {
  const sides = (["away", "home"] as const).flatMap((side) => {
    const broadcast = game.broadcasts.find((candidate) => candidate.side === side);
    return broadcast ? [{ side, team: game[side].team.club, channel: broadcast.name }] : [];
  });
  if (sides.length > 0) return sides;
  return [{ side: "home", team: null, channel: game.broadcasts[0]?.name ?? null }];
}

/** A day's games grouped as Baseball shows them, empty groups left out. */
export function groupGames(games: BaseballGame[]): { state: BaseballGameState; games: BaseballGame[] }[] {
  return BASEBALL_STATE_ORDER.map((state) => ({ state, games: games.filter((game) => game.state === state) })).filter(
    (group) => group.games.length > 0,
  );
}

/** How often to ask again: every few seconds while a game is on, now and then on today's, never on a day that's settled. */
export function refreshEvery(day: BaseballDay | undefined): number | false {
  if (!day) return false;
  if (day.games.some((game) => game.state === "live" || game.watchable)) return 15_000;
  return day.date === day.today ? 60_000 : false;
}
