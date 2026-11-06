import { useCallback, useEffect, useRef } from "react";
import { SEEK_SETTLE_MS } from "@/components/player/timing";

/**
 * Seeks from keys and buttons land together (docs/PERF_PROPOSAL.md › P14):
 * each press moves the bar at once, and the element goes to the last of a
 * quick run of them, so holding an arrow key asks the transcoder for one
 * place, not thirty. `element` is read when needed, so it can be a ref's.
 */
export function useSeekBatch(element: () => HTMLVideoElement | null) {
  const pending = useRef<number | null>(null);
  const timer = useRef<number | undefined>(undefined);
  useEffect(() => () => window.clearTimeout(timer.current), []);

  /** Where the viewer is, counting a seek that hasn't landed yet. */
  const position = useCallback(() => pending.current ?? element()?.currentTime ?? 0, [element]);
  /** A seek hasn't landed: the bar stays where it's going. */
  const seeking = useCallback(() => pending.current !== null, []);
  const seek = useCallback(
    (target: number, { now = false }: { now?: boolean } = {}) => {
      const video = element();
      if (!video) return;
      pending.current = target;
      window.clearTimeout(timer.current);
      const land = () => {
        const at = pending.current;
        pending.current = null;
        if (at !== null) video.currentTime = at;
      };
      if (now) land();
      else timer.current = window.setTimeout(land, SEEK_SETTLE_MS);
    },
    [element],
  );
  return { position, seeking, seek };
}
