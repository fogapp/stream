import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { PosterCard } from "@/components/viewing/cards";
import { ROW_POSTER, Row } from "@/components/viewing/Row";
import type { MovieCard, ShowCard } from "@/types";

/** More like this (PROPOSAL §7.1): the nearest titles by what they're made of. */
export function MoreLikeThis({ kind, id }: { kind: "movie" | "show"; id: string }) {
  const similar = useQuery({
    queryKey: kind === "movie" ? keys.movies.similar(id) : keys.shows.similar(id),
    queryFn: ({ signal }) => api.get<(MovieCard | ShowCard)[]>(`/${kind === "movie" ? "movies" : "shows"}/${id}/similar`, { signal }),
  });
  if (!similar.data || similar.data.length === 0) return null;
  return (
    <Row title="More like this">
      {similar.data.map((item) => (
        <PosterCard key={item.id} item={item} className={ROW_POSTER} />
      ))}
    </Row>
  );
}
