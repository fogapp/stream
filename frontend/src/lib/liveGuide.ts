import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import type { Guide } from "@/types";

/** An hour back to a few hours ahead: what's on now and next, for every channel. */
export function useNowGuide() {
  return useQuery({
    queryKey: keys.live.guide("now", "4h"),
    queryFn: ({ signal }) => {
      const now = Date.now();
      const from = new Date(now - 60 * 60_000).toISOString();
      const to = new Date(now + 4 * 3_600_000).toISOString();
      return api.get<Guide>(`/guide?from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`, { signal });
    },
    refetchInterval: 60_000,
  });
}
