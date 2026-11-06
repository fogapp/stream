import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import type { OptimizerStatus } from "@/types";

/** What the optimizer is doing: watched closely while something encodes, idly otherwise. */
export function useOptimizerStatus() {
  return useQuery({
    queryKey: keys.optimizedVersions.status(),
    queryFn: ({ signal }) => api.get<OptimizerStatus>("/optimized_versions/status", { signal }),
    refetchInterval: (query) => (query.state.data?.state === "encoding" ? 5_000 : 30_000),
  });
}
