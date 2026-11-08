import { useEffect, useState } from "react";
import { onAt } from "@/lib/live";
import type { Airing, GuideStation } from "@/types";

/**
 * What a channel is airing now and next, by the server's clock. Read again
 * at the next moment either changes — an airing starting or ending — rather
 * than every second, so the page re-renders when a program does.
 */
export function useOnNow(station: GuideStation | null, skew: number): { current: Airing | null; next: Airing | null } {
  const [tick, setTick] = useState(0);
  const serverNow = Date.now() + skew;
  const { current, next } = station ? onAt(station, serverNow) : { current: null, next: null };
  let boundary = Infinity;
  for (const airing of station?.airings ?? []) {
    for (const at of [Date.parse(airing.starts_at), Date.parse(airing.ends_at)]) if (at > serverNow && at < boundary) boundary = at;
  }
  useEffect(() => {
    if (!Number.isFinite(boundary)) return;
    // Rescheduled after each tick: a timer that wakes a moment early looks again.
    const timer = window.setTimeout(() => setTick((count) => count + 1), Math.max(boundary - (Date.now() + skew), 0) + 1);
    return () => window.clearTimeout(timer);
  }, [boundary, skew, tick]);
  return { current, next };
}
