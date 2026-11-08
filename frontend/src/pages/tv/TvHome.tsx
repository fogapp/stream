import { useQuery } from "@tanstack/react-query";
import { homeHubsQuery } from "@/lib/queries";
import { TvCard } from "@/components/tv/TvCard";
import { TvShell } from "@/components/tv/TvShell";
import { QueryState } from "@/components/ui/PageState";
import { clockSkew, onAt } from "@/lib/live";
import { useNowGuide } from "@/lib/liveGuide";
import type { HomeHub } from "@/types";

/** The TV's home (PROPOSAL §7.4): the same rows as the desktop, a remote's width apart. */
export function TvHome() {
  const hubs = useQuery(homeHubsQuery());
  return (
    <TvShell ready={Boolean(hubs.data)}>
      <QueryState query={hubs} errorMessage="Could not load home.">
        {(data) => (
          <div className="space-y-10 pt-8">
            <OnNow />
            {data.hubs.map((hub) => (
              <TvRow key={hub.key} hub={hub} />
            ))}
          </div>
        )}
      </QueryState>
    </TvShell>
  );
}

/** Grid, first thing (PROPOSAL §7.7): what each channel is airing now. */
function OnNow() {
  const guide = useNowGuide();
  const data = guide.data;
  if (!data || data.stations.length === 0) return null;
  const now = Date.now() + clockSkew(data.now, guide.dataUpdatedAt);
  return (
    <section aria-label="On now" className="space-y-4">
      <h2 className="px-12 text-2xl font-semibold">On now</h2>
      <div className="scrollbar-none flex gap-6 overflow-x-auto px-12 py-3">
        {data.stations.map((station) => {
          const { current } = onAt(station, now);
          return (
            <TvCard
              key={station.id}
              wide
              to={`/live/${encodeURIComponent(station.number)}`}
              image={current ? (current.images.still ?? current.images.backdrop ?? current.images.poster) : null}
              title={`${station.number} · ${station.name}`}
              detail={current ? [current.title, current.subtitle].filter(Boolean).join(" · ") : "Between programs"}
            />
          );
        })}
      </div>
    </section>
  );
}

function TvRow({ hub }: { hub: HomeHub }) {
  return (
    <section aria-label={hub.title} className="space-y-4">
      <h2 className="px-12 text-2xl font-semibold">{hub.title}</h2>
      <div className="scrollbar-none flex gap-6 overflow-x-auto px-12 py-3">
        {hub.kind === "poster"
          ? hub.items.map((item) => (
              <TvCard
                key={item.id}
                to={`/tv/${item.kind}/${item.id}`}
                image={item.images.poster ?? item.images.thumb}
                title={item.title}
                detail={item.kind === "show" ? item.arrival : item.year?.toString()}
              />
            ))
          : hub.kind === "videos"
            ? hub.items.map((item) => (
                <TvCard key={item.id} wide to={`/watch/video/${item.id}`} image={item.images.thumb} title={item.title} detail={item.channel?.title} progress={item.progress} />
              ))
            : hub.kind === "clips"
              ? hub.items.map((item) => (
                  <TvCard key={item.id} wide to={`/watch/clip/${item.id}`} image={item.images.thumb} title={item.city ?? item.title} progress={item.progress} />
                ))
              : hub.items.map((item) => {
                  if (item.kind === "show") {
                    return (
                      <TvCard key={`show-${item.id}`} wide to={`/tv/show/${item.id}`} image={item.images.backdrop ?? item.images.thumb} title={item.title} detail={item.arrival} />
                    );
                  }
                  const image =
                    item.kind === "episode"
                      ? (item.images.still ?? item.images.thumb ?? item.show?.images.backdrop)
                      : item.kind === "video"
                        ? item.images.thumb
                        : (item.images.backdrop ?? item.images.thumb);
                  const title = item.kind === "episode" ? (item.show?.title ?? item.code) : item.title;
                  const detail = item.kind === "episode" ? [item.code, item.title].filter(Boolean).join(" · ") : null;
                  return <TvCard key={`${item.kind}-${item.id}`} wide to={`/watch/${item.kind}/${item.id}`} image={image} title={title} detail={detail} progress={item.progress} />;
                })}
      </div>
    </section>
  );
}
