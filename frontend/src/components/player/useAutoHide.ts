import { useCallback, useEffect, useRef, useState } from "react";

const HIDE_CONTROLS_MS = 3_000;

/**
 * A player's controls: shown on any movement, and hidden a few seconds
 * later unless the picture is paused. `show` keeps them up (a pause).
 */
export function useAutoHide(paused: () => boolean) {
  const [shown, setShown] = useState(true);
  const timer = useRef<number | undefined>(undefined);
  // Asked when the time comes, of whatever element is playing then.
  const isPaused = useRef(paused);
  isPaused.current = paused;
  const reveal = useCallback(() => {
    setShown(true);
    window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => {
      if (!isPaused.current()) setShown(false);
    }, HIDE_CONTROLS_MS);
  }, []);
  const show = useCallback(() => setShown(true), []);
  useEffect(() => () => window.clearTimeout(timer.current), []);
  return { shown, reveal, show };
}
