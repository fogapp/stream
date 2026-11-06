import { useQuery } from "@tanstack/react-query";
import { useSearchParams } from "react-router-dom";
import { api } from "@/api/client";
import { GameCard } from "@/components/basketball/GameCard";
import { PageHeader } from "@/components/layout/PageHeader";
import { DayPicker } from "@/components/sports/DayPicker";
import { GameGroup } from "@/components/sports/Scoreboard";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import { BASKETBALL_STATE_LABELS, groupGames, refreshEvery } from "@/lib/basketball";
import { keys } from "@/lib/queryKeys";
import type { BasketballDay } from "@/types";

/**
 * Basketball (PROPOSAL §7.8): a day of NBA games from the NBA's schedule, as
 * a scoreboard — live first, then what's coming, then how the rest ended —
 * asked again every few seconds while a game is on. League Pass games are
 * DRM-protected, so a game is watched on NBA.com, not in Stream's player.
 */
export function Basketball() {
  const [params, setParams] = useSearchParams();
  const asked = params.get("date");
  const day = useQuery({
    queryKey: keys.basketball.day(asked),
    queryFn: ({ signal }) => api.get<BasketballDay>(`/basketball/games${asked ? `?date=${encodeURIComponent(asked)}` : ""}`, { signal }),
    refetchInterval: (query) => refreshEvery(query.state.data),
  });
  const go = (date: string | null) => setParams(date ? { date } : {});

  const shown = day.data;
  return (
    <div className="pb-8">
      <PageHeader
        title="Basketball"
        description="NBA games on League Pass: what's on, what's next, and how the rest ended. Games play on NBA.com."
        actions={shown ? <DayPicker day={shown} onDay={go} /> : null}
      />
      <div className="space-y-8 px-4 py-6 sm:px-6 lg:px-8">
        <QueryState query={day} errorMessage="Could not load the NBA's schedule.">
          {(data) =>
            data.games.length === 0 ? (
              <EmptyState
                title="No games"
                description={data.next_date ? "Nothing's scheduled this day. The arrows go to the days with games." : "The NBA has nothing scheduled yet."}
              />
            ) : (
              groupGames(data.games).map((group) => (
                <GameGroup key={group.state} id={`basketball-${group.state}`} label={BASKETBALL_STATE_LABELS[group.state]}>
                  {group.games.map((game) => (
                    <GameCard key={game.id} game={game} watchUrl={data.watch_url} />
                  ))}
                </GameGroup>
              ))
            )
          }
        </QueryState>
      </div>
    </div>
  );
}
