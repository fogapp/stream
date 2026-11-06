import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "@/api/client";
import { describeOptimizeResult } from "@/lib/optimized";
import { keys } from "@/lib/queryKeys";
import { toast } from "@/components/ui/Toast";
import type { OptimizeAction, OptimizeActionResult } from "@/types";

/** How long the hourly pass usually takes to queue what it finds. */
const SCAN_SETTLES_MS = 3_000;

/**
 * Everything an admin does to optimized versions — on one file's page or
 * many rows of the Playback page — and the one place that says what
 * happened and refreshes whatever showed it. Failures toast through the
 * mutation cache like any other.
 */
export function useOptimizeActions() {
  const queryClient = useQueryClient();
  const refresh = () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: keys.playbackDecisions.all }),
      queryClient.invalidateQueries({ queryKey: keys.optimizedVersions.all }),
      queryClient.invalidateQueries({ queryKey: keys.mediaFiles.all }),
    ]);

  const act = useMutation({
    mutationFn: ({ action, ids, now = false }: { action: OptimizeAction; ids: string[]; now?: boolean }) =>
      api.post<OptimizeActionResult>("/optimized_versions/bulk", { bulk_action: action, media_file_ids: ids, now }),
    onSuccess: (result, { action }) => {
      toast.info(describeOptimizeResult(action, result));
      return refresh();
    },
  });

  const scan = useMutation({
    mutationFn: () => api.post("/optimized_versions/scan"),
    onSuccess: () => {
      toast.info("Looking for files to optimize…");
      window.setTimeout(() => void refresh(), SCAN_SETTLES_MS);
    },
  });

  const pause = useMutation({
    mutationFn: (paused: boolean) => api.patch("/app_setting", { optimize_paused: paused }),
    onSuccess: (_result, paused) => {
      toast.info(paused ? "Optimizing paused: only versions asked for now are encoded." : "Optimizing resumed.");
      void queryClient.invalidateQueries({ queryKey: keys.settings.all });
      return refresh();
    },
  });

  return { act, scan, pause };
}
