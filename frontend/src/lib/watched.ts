import type { Query, QueryClient } from "@tanstack/react-query";
import { keys } from "@/lib/queryKeys";

/** Everything a watched change can move: badges, rows, counts, Up next. */
const MOVED = [
  keys.movies.all,
  keys.shows.all,
  keys.videos.all,
  keys.channels.all,
  keys.clips.all,
  keys.home.all,
  keys.subscriptions.all,
  keys.playlists.all,
  keys.collections.all,
  keys.people.all,
];

type Changed = { kind: string; id: string; watched: boolean };
type Card = { kind?: string; id?: string; watched?: boolean; unwatched_count?: number };

/** An endless wall of cards: refetching it fetches every page loaded so far. */
const isWall = (query: Query) => {
  const data = query.state.data;
  return typeof data === "object" && data !== null && "pages" in data;
};

/** A wall filtered to what's unwatched (its key's filters say `unwatched: true`). */
const isUnwatchedWall = (query: Query) =>
  query.queryKey.some((part) => typeof part === "object" && part !== null && (part as { unwatched?: unknown }).unwatched === true);

/**
 * After marking something watched or not. Everything it moves is refetched
 * where it's on screen — except a library's endless wall, which would ask
 * again for every page loaded: its card changes where it is (or, on a wall
 * of what's unwatched, leaves it once watched), and the wall is fetched
 * afresh the next time it's opened.
 */
export function refreshWatched(queryClient: QueryClient, changed?: Changed) {
  if (changed) {
    for (const query of queryClient.getQueryCache().findAll({ predicate: isWall })) {
      const leaves = changed.watched && isUnwatchedWall(query);
      queryClient.setQueryData<{ pages: unknown[] }>(query.queryKey, (data) =>
        data && {
          ...data,
          pages: data.pages.map((page) => {
            if (!Array.isArray(page)) return page;
            const matches = (card: Card) => card.id === changed.id && card.kind === changed.kind;
            if (leaves) return page.filter((card: Card) => !matches(card));
            return page.map((card: Card) => {
              if (!matches(card)) return card;
              if (changed.kind === "show") return changed.watched ? { ...card, unwatched_count: 0 } : card;
              return { ...card, watched: changed.watched };
            });
          }),
        },
      );
    }
  }
  for (const key of MOVED) {
    void queryClient.invalidateQueries({ queryKey: key, predicate: (query) => !isWall(query) });
    void queryClient.invalidateQueries({ queryKey: key, predicate: isWall, refetchType: "none" });
  }
}
