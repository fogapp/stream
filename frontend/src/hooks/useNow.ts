import { useEffect, useState } from "react";

/**
 * The time, ticking every `every` ms (null: holding still): Date.now() plus
 * `skew`, for the server's clock. Used by the small thing that shows a time,
 * so a clock re-renders that and not the player around it.
 */
export function useNow(every: number | null = 1_000, skew = 0): number {
  const [now, setNow] = useState(() => Date.now() + skew);
  useEffect(() => {
    if (every === null) return;
    setNow(Date.now() + skew);
    const timer = window.setInterval(() => setNow(Date.now() + skew), every);
    return () => window.clearInterval(timer);
  }, [every, skew]);
  return now;
}
