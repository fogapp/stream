import { useCallback, useEffect, useRef } from "react";
import type { PlayFailure } from "@/components/player/failure";
import type { PlayerEvent } from "@/components/player/useSessionReporting";

/** A wait that doesn't end in this long is a play that's stuck (R2). */
const STUCK_AFTER_MS = 30_000;
/** Shorter than this, it's not worth reporting as a stall. */
const NOTICED_AFTER_MS = 500;

/** Waits in the middle of a play, for the video element's own events: noted when they end, and given up on when they don't. */
export function useStallWatch(note: (event: PlayerEvent) => void, fallBack: (failure: PlayFailure) => void) {
  const stalledAt = useRef<number | null>(null);
  const stallTimer = useRef<number | undefined>(undefined);
  useEffect(() => () => window.clearTimeout(stallTimer.current), []);

  const onWaiting = useCallback(
    (element: HTMLVideoElement) => {
      if (element.paused || element.seeking) return;
      stalledAt.current = performance.now();
      window.clearTimeout(stallTimer.current);
      stallTimer.current = window.setTimeout(() => {
        if (stalledAt.current !== null && !element.paused) fallBack({ failureClass: "stalled", cause: "waited 30 s for the stream" });
      }, STUCK_AFTER_MS);
    },
    [fallBack],
  );
  const onPlaying = useCallback(
    (element: HTMLVideoElement) => {
      window.clearTimeout(stallTimer.current);
      const began = stalledAt.current;
      stalledAt.current = null;
      if (began !== null && performance.now() - began > NOTICED_AFTER_MS) {
        note({ kind: "stall", position: element.currentTime, detail: { seconds: Math.round(performance.now() - began) / 1000 } });
      }
    },
    [note],
  );
  return { onWaiting, onPlaying };
}
