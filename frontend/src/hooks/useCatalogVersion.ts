import { useEffect, useRef } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import type { CatalogVersion } from "@/types";

/** How often an open, visible tab asks whether the catalog moved. */
export const CATALOG_POLL_MS = 5_000;

/** What a new or vanished file can change: every list of titles, search, and Hook's In Stream marks. */
export const CATALOG_KEYS = [
  keys.home.all,
  keys.search.all,
  keys.hook.all,
  keys.movies.all,
  keys.shows.all,
  keys.videos.all,
  keys.channels.all,
  keys.collections.all,
  keys.people.all,
] as const;

/**
 * Refreshes the catalog the moment something arrives or leaves — a film Hook
 * delivered, an episode Sonarr imported — without a reload. The version is one
 * count on the server; only a change to it refetches anything, and a hidden tab
 * doesn't ask (it catches up when it's looked at again).
 */
export function useCatalogVersion(): void {
  const queryClient = useQueryClient();
  const { data } = useQuery({
    queryKey: keys.catalog.version(),
    queryFn: ({ signal }) => api.get<CatalogVersion>("/catalog_version", { signal }),
    select: (response) => response.version,
    refetchInterval: CATALOG_POLL_MS,
  });
  const seen = useRef<string | undefined>(undefined);
  useEffect(() => {
    if (data === undefined) return;
    const previous = seen.current;
    seen.current = data;
    if (previous === undefined || previous === data) return;
    for (const queryKey of CATALOG_KEYS) void queryClient.invalidateQueries({ queryKey });
  }, [data, queryClient]);
}
