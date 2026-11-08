import { useState, useSyncExternalStore, type ReactNode } from "react";

/**
 * Where the player is, a few times a second: kept outside React state so
 * a timeupdate re-renders only what shows it (the bar, the clock, the skip
 * buttons), not the whole player and its menus.
 */
export interface Playhead {
  get: () => number;
  set: (seconds: number) => void;
  subscribe: (listener: () => void) => () => void;
}

export function usePlayhead(start: number): Playhead {
  const [playhead] = useState<Playhead>(() => {
    let seconds = start;
    const listeners = new Set<() => void>();
    return {
      get: () => seconds,
      set: (next) => {
        if (next === seconds) return;
        seconds = next;
        for (const listener of listeners) listener();
      },
      subscribe: (listener) => {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
    };
  });
  return playhead;
}

/** Something about the playhead, re-rendering only when it changes (a boolean, say). */
export function usePlayheadValue<T>(playhead: Playhead, select: (seconds: number) => T): T {
  return useSyncExternalStore(playhead.subscribe, () => select(playhead.get()));
}

/** Renders its children with the playhead, and re-renders only them as it moves. */
export function AtPlayhead({ playhead, children }: { playhead: Playhead; children: (seconds: number) => ReactNode }) {
  return children(usePlayheadValue(playhead, (seconds) => seconds));
}

/**
 * How far through it is, in thousandths (the corner's and the inset's bar):
 * enough to see, few enough renders — and only the bar re-renders.
 */
export function AtProgress({ playhead, duration, children }: { playhead: Playhead; duration: number; children: (progress: number) => ReactNode }) {
  return children(usePlayheadValue(playhead, (seconds) => (duration > 0 ? Math.round(Math.min(seconds / duration, 1) * 1000) / 1000 : 0)));
}
