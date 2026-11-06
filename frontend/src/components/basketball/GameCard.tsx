import { LiveMark } from "@/components/sports/Scoreboard";
import { ExternalLink, Tv } from "lucide-react";
import { ButtonLink } from "@/components/ui/Button";
import { cn } from "@/lib/cn";
import { BASKETBALL_WATCH_LABELS, periodLabel, startTime } from "@/lib/basketball";
import type { BasketballGame, BasketballGameSide, BasketballSide } from "@/types";

/**
 * One game, as a scoreboard shows it (PROPOSAL §7.8): both teams with their
 * logos and records, the score, and — while it's on — the quarter and
 * clock; before it, the start; after it, the line score and top scorers.
 * League Pass games are DRM-protected, so Stream can't play them: the
 * card's link opens the day's games on NBA.com, where League Pass does.
 */
export function GameCard({ game, watchUrl }: { game: BasketballGame; watchUrl: string }) {
  const matchup = `${game.away.team.name} at ${game.home.team.name}`;
  const watch = BASKETBALL_WATCH_LABELS[game.state];
  const heading = game.series
    ? [game.series.name, game.series.status].filter(Boolean).join(" · ")
    : [game.preseason ? "Preseason" : null, game.venue].filter(Boolean).join(" · ");

  return (
    <article className="flex flex-col overflow-hidden rounded-[var(--radius-card)] border border-border bg-surface" aria-label={matchup}>
      <header className="flex min-h-5 items-center justify-between gap-2 px-4 pt-3 text-xs text-muted">
        <span className="min-w-0 truncate">{heading}</span>
        {game.state === "live" ? <LiveMark /> : null}
      </header>
      <div className="flex items-stretch gap-3 px-4 py-3">
        <div className="min-w-0 flex-1 space-y-2.5">
          <TeamRow side={game.away} game={game} />
          <TeamRow side={game.home} game={game} />
        </div>
        <div className="flex w-24 shrink-0 flex-col items-center justify-center gap-1.5 border-l border-border pl-3 text-center">
          <Situation game={game} />
        </div>
      </div>
      {game.periods.length > 0 ? <LineScore game={game} /> : null}
      <footer className="mt-auto flex min-h-11 flex-wrap items-center gap-x-3 gap-y-2 border-t border-border px-4 py-2 text-xs text-muted">
        {watch ? (
          <ButtonLink href={watchUrl} size="sm" variant={game.state === "live" ? "primary" : "secondary"} aria-label={`${watch}: ${matchup}`}>
            <ExternalLink className="h-3.5 w-3.5" aria-hidden />
            {watch}
          </ButtonLink>
        ) : null}
        <Details game={game} />
      </footer>
    </article>
  );
}

function TeamRow({ side, game }: { side: BasketballGameSide; game: BasketballGame }) {
  const lost = game.state === "final" && !side.winner;
  return (
    <div className="flex items-center gap-3">
      {/* A hairline in the text color keeps a dark logo seen on the dark theme (and a pale one on the light). */}
      {side.team.logo_url ? (
        <img
          src={side.team.logo_url}
          alt=""
          className="h-8 w-8 shrink-0 object-contain [filter:drop-shadow(0_0_0.75px_color-mix(in_oklch,var(--color-foreground)_70%,transparent))]"
          loading="lazy"
        />
      ) : (
        <span className="h-8 w-8 shrink-0" aria-hidden />
      )}
      <p className={cn("min-w-0 flex-1 truncate text-base font-semibold", lost ? "text-muted" : "text-foreground")}>
        <span className="sm:hidden">{side.team.abbreviation}</span>
        <span className="hidden sm:inline">{side.team.club}</span>
        {side.record ? <span className="ml-2 text-xs font-normal text-muted">{side.record}</span> : null}
      </p>
      {side.score !== null ? (
        <span className={cn("text-2xl font-bold tabular-nums", lost ? "text-muted" : "text-foreground")}>{side.score}</span>
      ) : null}
    </div>
  );
}

/** What's happening now: the quarter and clock, the start, or how it ended — in ESPN's words. */
function Situation({ game }: { game: BasketballGame }) {
  if (game.state === "upcoming") return <span className="text-sm font-semibold text-foreground">{startTime(game)}</span>;
  if (game.state === "off") return <span className="text-xs font-medium text-warning">{game.status}</span>;
  return <span className="text-sm font-semibold text-foreground">{game.status}</span>;
}

/** Points by quarter, overtimes after, then the total. */
function LineScore({ game }: { game: BasketballGame }) {
  const count = Math.max(game.scheduled_periods, ...game.periods.map((period) => period.number));
  const columns = Array.from({ length: count }, (_, index) => index + 1);
  const row = (side: BasketballSide) => (
    <tr>
      <th scope="row" className="pr-2 text-left font-medium text-muted">
        {game[side].team.abbreviation}
      </th>
      {columns.map((number) => (
        <td key={number} className="text-center tabular-nums text-muted">
          {game.periods.find((period) => period.number === number)?.[side] ?? ""}
        </td>
      ))}
      <td className="pl-1 text-center font-semibold tabular-nums text-foreground">{game[side].score ?? ""}</td>
    </tr>
  );
  return (
    <div className="overflow-x-auto px-4 pb-3">
      <table className="w-full min-w-[12rem] text-xs">
        <thead>
          <tr className="text-muted">
            <th scope="col" className="sr-only">
              Team
            </th>
            {columns.map((number) => (
              <th key={number} scope="col" className="w-7 text-center font-normal">
                {periodLabel(number)}
              </th>
            ))}
            <th scope="col" className="w-7 pl-1 text-center font-semibold text-foreground">
              T
            </th>
          </tr>
        </thead>
        <tbody>
          {row("away")}
          {row("home")}
        </tbody>
      </table>
    </div>
  );
}

/** Beside the link: the top scorers once it's on, or who's on TV. */
function Details({ game }: { game: BasketballGame }) {
  const leaders = (["away", "home"] as const).flatMap((side) => {
    const leader = game[side].leader;
    return leader && leader.points > 0 ? [`${leader.name} ${leader.points}`] : [];
  });
  if (game.state !== "upcoming" && leaders.length > 0) return <span className="min-w-0 truncate">{leaders.join(" · ")}</span>;
  if (game.broadcasts.length === 0) return null;
  return (
    <span className="inline-flex min-w-0 items-center gap-1.5 truncate">
      <Tv className="h-3.5 w-3.5 shrink-0" aria-hidden />
      {game.broadcasts.map((broadcast) => broadcast.name).join(" · ")}
    </span>
  );
}
