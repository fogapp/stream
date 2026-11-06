import { useQuery } from "@tanstack/react-query";
import { useParams } from "react-router-dom";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { librariesQuery } from "@/lib/queries";
import { TvCard } from "@/components/tv/TvCard";
import { TvShell } from "@/components/tv/TvShell";
import { EmptyState, LoadingState } from "@/components/ui/PageState";
import type { Library, MovieCard, ShowCard } from "@/types";
import { TvChannels, TvHomeVideos, TvLiveStreams } from "@/pages/tv/TvLibraryKinds";

/** A film or TV library on the TV (PROPOSAL §7.4): every poster, A to Z. */
export function TvLibrary() {
  const { id = "" } = useParams();
  const libraries = useQuery(librariesQuery());
  const library = libraries.data?.find((candidate) => candidate.id === id);
  if (library?.kind === "channels") return <TvChannels library={library} />;
  if (library?.kind === "home_videos") return <TvHomeVideos library={library} />;
  if (library?.kind === "live") return <TvLiveStreams library={library} />;
  return <TvTitles id={id} library={library} failed={libraries.isError} />;
}

/** A film or TV library. */
function TvTitles({ id, library, failed }: { id: string; library: Library | undefined; failed: boolean }) {
  const shows = library?.kind === "shows";
  const titles = useQuery({
    queryKey: shows ? keys.shows.list({ library_id: id, sort: "title" }) : keys.movies.list({ library_id: id, sort: "title" }),
    queryFn: ({ signal }) => api.get<(MovieCard | ShowCard)[]>(`/${shows ? "shows" : "movies"}?library_id=${id}&sort=title&per=500`, { signal }),
    enabled: Boolean(library),
  });

  return (
    <TvShell ready={Boolean(titles.data)}>
      <div className="space-y-8 px-12 pt-8">
        <h1 className="text-3xl font-bold">{library?.name ?? "Library"}</h1>
        {titles.isError || failed ? (
          <p className="text-xl text-negative">This library didn't load.</p>
        ) : !titles.data ? (
          <LoadingState />
        ) : titles.data.length === 0 ? (
          <EmptyState title="Nothing here yet" description="Once it's scanned, its titles appear here." />
        ) : (
          <div className="flex flex-wrap gap-6">
            {titles.data.map((title) => (
              <TvCard
                key={title.id}
                to={`/tv/${title.kind}/${title.id}`}
                image={title.images.poster}
                title={title.title}
                detail={title.kind === "show" && title.unwatched_count ? `${title.unwatched_count} unwatched` : title.year?.toString()}
                progress={title.kind === "movie" ? title.progress : null}
              />
            ))}
          </div>
        )}
      </div>
    </TvShell>
  );
}
