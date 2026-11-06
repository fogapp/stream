import { useCallback } from "react";
import { useQuery, useQueryClient, type QueryKey } from "@tanstack/react-query";
import { api } from "@/api/client";
import { useTestConnection } from "@/hooks/useTestConnection";

/**
 * A connection in Settings: what's stored (`current` is null until it's set
 * up — and while nothing is known, which is why its form goes inside a
 * QueryState: a failed load must not read as "not set up" and save blanks
 * over what is), its Test, and `saved` for a save that answers with the
 * settings. `resource` is the entry in queryKeys.ts.
 */
export function useConnectionSettings<T extends { configured: boolean }>(path: string, resource: { settings: () => QueryKey; all: QueryKey }) {
  const queryClient = useQueryClient();
  const queryKey = resource.settings();
  const settings = useQuery({ queryKey, queryFn: ({ signal }) => api.get<T>(path, { signal }) });
  const test = useTestConnection(`${path}/test`, resource.all);
  const current = settings.data?.configured ? (settings.data as Extract<T, { configured: true }>) : null;
  const saved = useCallback((data: T) => queryClient.setQueryData(queryKey, data), [queryClient, queryKey]);
  return { settings, test, current, saved };
}
