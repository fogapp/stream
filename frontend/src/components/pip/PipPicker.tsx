import type { ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import { Check, PictureInPicture2, Play, Tv } from "lucide-react";
import { api } from "@/api/client";
import { BaseballIcon } from "@/components/baseball/BaseballIcon";
import { ActionMenu, ActionMenuItem, ActionMenuSeparator } from "@/components/ui/ActionMenu";
import { usePlayback, usePlaybackActions } from "@/hooks/usePlayback";
import { useWatchGame } from "@/hooks/useWatchGame";
import { watchChoices } from "@/lib/baseball";
import { onAt } from "@/lib/live";
import { LIVE_STREAM_KIND_OPTIONS } from "@/lib/liveStreams";
import { useNowGuide } from "@/lib/liveGuide";
import { sameSource, type PipSource } from "@/lib/pip";
import { baseballDayQuery, baseballQuery, homeHubsQuery } from "@/lib/queries";
import { keys } from "@/lib/queryKeys";
import type { EpisodeCard, LiveStream, MovieCard, VideoCard } from "@/types";

/** Looks like the player's own buttons beside it. */
const TRIGGER = "h-auto w-auto rounded-[var(--radius-control)] bg-transparent p-2.5 text-muted hover:bg-surface-raised hover:text-foreground";

function cardSource(card: MovieCard | EpisodeCard | VideoCard): PipSource {
  const title = card.kind === "episode" ? [card.show?.title, card.code].filter(Boolean).join(" · ") || (card.title ?? "Episode") : card.title;
  return { kind: "title", playable: card.kind, id: card.id, title };
}

/**
 * The player's picture-in-picture button (PROPOSAL §7.3): something else
 * to watch in the inset over what's playing — a camera, a baseball game
 * on now, a Grid channel on now, or something from Continue watching. Anything else is a Play away
 * on its own page, as Picture in picture beside Play.
 */
export function PipPicker({ playing }: { playing: PipSource }) {
  const { openPip } = usePlaybackActions();
  return (
    <ActionMenu label="Picture in picture" className={TRIGGER} icon={<PictureInPicture2 className="h-5 w-5" aria-hidden />}>
      {(close) => (
        <PipChoices
          playing={playing}
          onChoose={(source) => {
            openPip(source);
            close();
          }}
        />
      )}
    </ActionMenu>
  );
}

function PipChoices({ playing, onChoose }: { playing: PipSource; onChoose: (source: PipSource) => void }) {
  const { pip } = usePlayback();
  const streams = useQuery({ queryKey: keys.liveStreams.list(), queryFn: ({ signal }) => api.get<LiveStream[]>("/live_streams", { signal }) });
  const guide = useNowGuide();
  const home = useQuery(homeHubsQuery());
  // Baseball's games on now, once there's an MLB.tv account: a team's stream, found when it's chosen.
  const baseball = useQuery(baseballQuery());
  const day = useQuery({
    ...baseballDayQuery(null),
    enabled: baseball.data?.available === true,
  });
  const games = (day.data?.games ?? []).filter((game) => game.watchable);
  const watch = useWatchGame((answer) => onChoose({ kind: "stream", id: answer.live_stream_id, title: answer.name }));

  const now = Date.now();
  const stations = (guide.data?.stations ?? []).flatMap((station) => {
    const airing = onAt(station, now).current;
    return airing ? [{ station, airing }] : [];
  });
  const hub = home.data?.hubs.find((candidate) => candidate.kind === "continue");
  const continuing = hub?.kind === "continue" ? hub.items : [];

  const item = (source: PipSource, label: string, icon: ReactNode, key: string) => {
    const main = sameSource(source, playing);
    const inset = sameSource(source, pip);
    return (
      <ActionMenuItem key={key} icon={inset ? <Check className="h-4 w-4" aria-hidden /> : icon} disabled={main || inset} onSelect={() => onChoose(source)}>
        {label}
        {main ? <span className="text-muted"> · playing</span> : null}
      </ActionMenuItem>
    );
  };
  const status = (query: { isPending: boolean; isError: boolean }, what: string) =>
    query.isPending ? <p className="px-2.5 py-1.5 text-sm text-muted">Loading {what}…</p> : query.isError ? <p className="px-2.5 py-1.5 text-sm text-negative">Couldn't load {what}.</p> : null;

  return (
    <div className="w-72">
      {streams.isPending || streams.isError || (streams.data?.length ?? 0) > 0 ? <ActionMenuSeparator label="Cameras and streams" /> : null}
      {status(streams, "streams")}
      {streams.data?.map((stream) => {
        const Icon = LIVE_STREAM_KIND_OPTIONS[stream.kind].icon;
        return item({ kind: "stream", id: stream.id, title: stream.name }, stream.name, <Icon className="h-4 w-4" aria-hidden />, `stream:${stream.id}`);
      })}
      {games.length > 0 ? <ActionMenuSeparator label="Baseball now" /> : null}
      {games.flatMap((game) =>
        watchChoices(game).map((choice) => (
          <ActionMenuItem
            key={`game:${game.id}:${choice.side}`}
            icon={<BaseballIcon className="h-4 w-4" aria-hidden />}
            disabled={watch.isPending}
            onSelect={() => watch.mutate({ gameId: game.id, side: choice.side })}
          >
            {game.away.team.abbreviation} at {game.home.team.abbreviation}
            <span className="text-muted"> · {choice.team ? `${choice.team} broadcast` : (choice.channel ?? "MLB.tv")}</span>
          </ActionMenuItem>
        )),
      )}
      {guide.isPending || guide.isError || stations.length > 0 ? <ActionMenuSeparator label="On the Grid now" /> : null}
      {status(guide, "the guide")}
      {stations.map(({ station, airing }) =>
        item(
          { kind: "station", stationId: station.id, number: station.number, title: station.name },
          `${station.number} ${station.name} · ${airing.title}`,
          <Tv className="h-4 w-4" aria-hidden />,
          `station:${station.id}`,
        ),
      )}
      {home.isPending || home.isError || continuing.length > 0 ? <ActionMenuSeparator label="Continue watching" /> : null}
      {status(home, "Continue watching")}
      {continuing.map((card) => {
        const source = cardSource(card);
        return item(source, source.title, <Play className="h-4 w-4" aria-hidden />, `${card.kind}:${card.id}`);
      })}
      {streams.isSuccess && guide.isSuccess && home.isSuccess && streams.data.length + stations.length + continuing.length + games.length === 0 ? (
        <p className="px-2.5 py-2 text-sm text-muted">Nothing to offer here. On any title's page, Picture in picture is beside Play.</p>
      ) : null}
    </div>
  );
}
