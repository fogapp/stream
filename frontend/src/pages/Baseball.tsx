import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useNavigate, useSearchParams } from "react-router-dom";
import { GameCard } from "@/components/baseball/GameCard";
import { PageHeader } from "@/components/layout/PageHeader";
import { DayPicker } from "@/components/sports/DayPicker";
import { GameGroup } from "@/components/sports/Scoreboard";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import { useWatchGame } from "@/hooks/useWatchGame";
import { BASEBALL_STATE_LABELS, groupGames } from "@/lib/baseball";
import { baseballDayQuery } from "@/lib/queries";
import type { BaseballSide } from "@/types";

/**
 * Baseball (PROPOSAL §7.8): a day of MLB games from MLB's schedule, as a
 * scoreboard — live first, then what's coming, then how the rest ended —
 * asked again every few seconds while a game is on. Pressing a game that's
 * on plays it from MLB.tv as a team's stream, like any other live stream:
 * full screen, in picture in picture, or on a Grid channel.
 */
export function Baseball() {
  const [params, setParams] = useSearchParams();
  const asked = params.get("date");
  const navigate = useNavigate();
  const day = useQuery(baseballDayQuery(asked));
  const [starting, setStarting] = useState<{ gameId: number; side: BaseballSide } | null>(null);
  const watch = useWatchGame((answer) => navigate(`/stream/${answer.live_stream_id}`));
  const go = (date: string | null) => setParams(date ? { date } : {});

  const shown = day.data;
  return (
    <div className="pb-8">
      <PageHeader
        title="Baseball"
        description="MLB games on MLB.tv: what's on, what's next, and how the rest ended."
        actions={shown ? <DayPicker day={shown} onDay={go} /> : null}
      />
      <div className="space-y-8 px-4 py-6 sm:px-6 lg:px-8">
        <QueryState query={day} errorMessage="Could not load MLB's schedule.">
          {(data) =>
            data.games.length === 0 ? (
              <EmptyState
                title="No games"
                description={data.next_date ? "Nothing's scheduled this day. The arrows go to the days with games." : "MLB has nothing scheduled yet."}
              />
            ) : (
              groupGames(data.games).map((group) => (
                <GameGroup key={group.state} id={`baseball-${group.state}`} label={BASEBALL_STATE_LABELS[group.state]}>
                  {group.games.map((game) => (
                    <GameCard
                      key={game.id}
                      game={game}
                      starting={watch.isPending && starting?.gameId === game.id ? starting.side : null}
                      onWatch={(side) => {
                        setStarting({ gameId: game.id, side });
                        watch.mutate({ gameId: game.id, side });
                      }}
                    />
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
