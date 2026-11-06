import { LiveMark } from "@/components/sports/Scoreboard";
import { Play, Tv } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { cn } from "@/lib/cn";
import { finalLabel, inningLabel, startTime, watchChoices, type WatchChoice } from "@/lib/baseball";
import type { BaseballGame, BaseballGameSide, BaseballInning, BaseballSide } from "@/types";

/**
 * One game, as a scoreboard shows it (PROPOSAL §7.8): both teams with their
 * logos and records, the score, and — while it's on — the inning, count,
 * outs and who's on base; before it, the start and the probable pitchers;
 * after it, the line score and the decisions. Pressing it plays the first
 * broadcast on offer; each team's own is a button of its own.
 */
export function GameCard({
  game,
  starting,
  onWatch,
}: {
  game: BaseballGame;
  /** The side being started, while it is. */
  starting: BaseballSide | null;
  onWatch: (side: BaseballSide) => void;
}) {
  const choices = game.watchable ? watchChoices(game) : [];
  const matchup = `${game.away.team.name} at ${game.home.team.name}`;
  const body = (
    <div className="flex items-stretch gap-3 px-4 py-3">
      <div className="min-w-0 flex-1 space-y-2.5">
        <TeamRow side={game.away} game={game} />
        <TeamRow side={game.home} game={game} />
      </div>
      <div className="flex w-24 shrink-0 flex-col items-center justify-center gap-1.5 border-l border-border pl-3 text-center">
        <Situation game={game} />
      </div>
    </div>
  );

  return (
    <article className="flex flex-col overflow-hidden rounded-[var(--radius-card)] border border-border bg-surface" aria-label={matchup}>
      <header className="flex min-h-5 items-center justify-between gap-2 px-4 pt-3 text-xs text-muted">
        <span className="min-w-0 truncate">
          {game.series ? [game.series.name, game.series.status].filter(Boolean).join(" · ") : game.venue}
          {game.double_header ? ` · Game ${game.double_header}` : null}
        </span>
        {game.state === "live" ? <LiveMark /> : null}
      </header>
      {choices.length > 0 ? (
        <button
          type="button"
          onClick={() => onWatch(choices[0].side)}
          disabled={starting !== null}
          className="text-left transition-colors hover:bg-surface-raised disabled:opacity-60"
          aria-label={`Watch ${matchup}`}
        >
          {body}
        </button>
      ) : (
        body
      )}
      {game.innings.length > 0 ? <LineScore game={game} /> : null}
      <footer className="mt-auto flex min-h-11 flex-wrap items-center gap-x-3 gap-y-2 border-t border-border px-4 py-2 text-xs text-muted">
        {choices.length > 0 ? (
          choices.map((choice) => <WatchButton key={choice.side} choice={choice} starting={starting} onWatch={onWatch} />)
        ) : (
          <Details game={game} />
        )}
      </footer>
    </article>
  );
}

function TeamRow({ side, game }: { side: BaseballGameSide; game: BaseballGame }) {
  const decided = game.state === "final";
  const lost = decided && !side.winner;
  const scored = side.score !== null && (game.state === "live" || game.state === "final");
  return (
    <div className="flex items-center gap-3">
      {/* A hairline in the text color keeps a navy logo seen on the dark theme (and a pale one on the light). */}
      <img
        src={side.team.logo_url}
        alt=""
        className="h-8 w-8 shrink-0 object-contain [filter:drop-shadow(0_0_0.75px_color-mix(in_oklch,var(--color-foreground)_70%,transparent))]"
        loading="lazy"
      />
      <div className="min-w-0 flex-1">
        <p className={cn("truncate text-base font-semibold", lost ? "text-muted" : "text-foreground")}>
          <span className="sm:hidden">{side.team.abbreviation}</span>
          <span className="hidden sm:inline">{side.team.club}</span>
          {side.record ? <span className="ml-2 text-xs font-normal text-muted">{side.record}</span> : null}
        </p>
        {game.state === "upcoming" && side.probable_pitcher ? <p className="truncate text-xs text-muted">{side.probable_pitcher}</p> : null}
      </div>
      {scored ? (
        <span className={cn("text-2xl font-bold tabular-nums", lost ? "text-muted" : "text-foreground")}>{side.score}</span>
      ) : null}
    </div>
  );
}

/** What's happening now: the inning, bases, outs and count; the start; or how it ended. */
function Situation({ game }: { game: BaseballGame }) {
  if (game.state === "live" && game.inning) {
    const { inning } = game;
    return (
      <>
        <span className="text-sm font-semibold text-foreground">{inningLabel(inning)}</span>
        <Bases bases={inning.bases} />
        {inning.half === "top" || inning.half === "bottom" ? (
          <span className="flex items-center gap-1.5 text-xs text-muted">
            <Outs outs={inning.outs} />
            <span className="tabular-nums">
              {inning.balls}-{inning.strikes}
            </span>
          </span>
        ) : null}
      </>
    );
  }
  if (game.state === "live") return <span className="text-sm font-semibold text-foreground">{game.status}</span>;
  if (game.state === "final") return <span className="text-sm font-semibold text-foreground">{finalLabel(game)}</span>;
  if (game.state === "off") return <span className="text-xs font-medium text-warning">{game.status}</span>;
  return (
    <>
      <span className="text-sm font-semibold text-foreground">{startTime(game)}</span>
      {game.watchable ? <span className="text-xs text-positive">{game.status}</span> : null}
    </>
  );
}

/** The diamond: second at the top, first on the right. */
function Bases({ bases }: { bases: BaseballInning["bases"] }) {
  const base = (on: boolean, x: number, y: number) => (
    <rect
      x={x}
      y={y}
      width="8"
      height="8"
      transform={`rotate(45 ${x + 4} ${y + 4})`}
      className={on ? "fill-warning stroke-warning" : "fill-none stroke-muted"}
      strokeWidth="1.5"
    />
  );
  const runners = [bases.first && "first", bases.second && "second", bases.third && "third"].filter(Boolean);
  return (
    <svg viewBox="0 0 30 22" className="h-5 w-7" role="img" aria-label={runners.length ? `On ${runners.join(", ")}` : "Bases empty"}>
      {base(bases.second, 11, 2)}
      {base(bases.third, 3, 10)}
      {base(bases.first, 19, 10)}
    </svg>
  );
}

function Outs({ outs }: { outs: number }) {
  return (
    <span className="flex gap-0.5" role="img" aria-label={`${outs} ${outs === 1 ? "out" : "outs"}`}>
      {[0, 1, 2].map((index) => (
        <span key={index} className={cn("h-1.5 w-1.5 rounded-full", index < outs ? "bg-foreground" : "border border-muted")} />
      ))}
    </span>
  );
}

/** Runs by inning, then R, H and E. */
function LineScore({ game }: { game: BaseballGame }) {
  const count = Math.max(game.scheduled_innings, game.innings.length);
  const columns = Array.from({ length: count }, (_, index) => game.innings.find((inning) => inning.number === index + 1));
  const row = (side: BaseballSide) => (
    <tr>
      <th scope="row" className="pr-2 text-left font-medium text-muted">
        {game[side].team.abbreviation}
      </th>
      {columns.map((inning, index) => (
        <td key={index} className="text-center tabular-nums text-muted">
          {inning?.[side] ?? ""}
        </td>
      ))}
      <td className="pl-1 text-center font-semibold tabular-nums text-foreground">{game[side].score ?? ""}</td>
      <td className="text-center tabular-nums text-muted">{game[side].hits ?? ""}</td>
      <td className="text-center tabular-nums text-muted">{game[side].errors ?? ""}</td>
    </tr>
  );
  return (
    <div className="overflow-x-auto px-4 pb-3">
      <table className="w-full min-w-[16rem] text-xs">
        <thead>
          <tr className="text-muted">
            <th scope="col" className="sr-only">
              Team
            </th>
            {columns.map((_, index) => (
              <th key={index} scope="col" className="w-5 text-center font-normal">
                {index + 1}
              </th>
            ))}
            <th scope="col" className="w-5 pl-1 text-center font-semibold text-foreground">
              R
            </th>
            <th scope="col" className="w-5 text-center font-normal">
              H
            </th>
            <th scope="col" className="w-5 text-center font-normal">
              E
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

function WatchButton({ choice, starting, onWatch }: { choice: WatchChoice; starting: BaseballSide | null; onWatch: (side: BaseballSide) => void }) {
  return (
    <Button size="sm" variant="secondary" disabled={starting !== null} onClick={() => onWatch(choice.side)}>
      <Play className="h-3.5 w-3.5" aria-hidden />
      {starting === choice.side ? "Starting…" : choice.team ? `${choice.team} broadcast` : "Watch"}
      {choice.channel ? <span className="font-normal opacity-80">· {choice.channel}</span> : null}
    </Button>
  );
}

/** Below a game that can't be watched: who pitched it, or who's on TV. */
function Details({ game }: { game: BaseballGame }) {
  if (game.state === "final" && game.decisions) {
    const { winner, loser, save } = game.decisions;
    return (
      <span className="min-w-0 truncate">
        {[winner && `W: ${winner}`, loser && `L: ${loser}`, save && `S: ${save}`].filter(Boolean).join(" · ")}
      </span>
    );
  }
  if (game.broadcasts.length === 0) return <span>{game.venue}</span>;
  return (
    <span className="inline-flex min-w-0 items-center gap-1.5 truncate">
      <Tv className="h-3.5 w-3.5 shrink-0" aria-hidden />
      {game.broadcasts.map((broadcast) => broadcast.name).join(" · ")}
    </span>
  );
}
