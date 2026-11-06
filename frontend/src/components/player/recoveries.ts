export interface Recovery {
  /** What it recovered from: hls.js's name for it, or the player's own. */
  message: string;
  /** What the browser or hls.js said went wrong, the first time: a decoder's own words. */
  cause?: string;
  count: number;
  /** Where in the film it first happened. */
  position: number;
}

/**
 * What a player recovered from by itself, for the Playback decisions page:
 * counted by what it was, and sent a few seconds apart — a stream that's
 * wrong does the same thing many times over.
 */
export function recoveryLog(send: (recoveries: Recovery[]) => void, everyMs = 5_000) {
  const seen = new Map<string, Recovery>();
  let timer: number | undefined;
  const flush = () => {
    window.clearTimeout(timer);
    timer = undefined;
    if (seen.size === 0) return;
    const recoveries = [...seen.values()];
    seen.clear();
    send(recoveries);
  };
  return {
    add(message: string, position: number, cause?: string) {
      const before = seen.get(message);
      seen.set(message, before ? { ...before, count: before.count + 1 } : { message, count: 1, position, ...(cause ? { cause } : {}) });
      timer ??= window.setTimeout(flush, everyMs);
    },
    /** Send what there is now: the player is going away. */
    flush,
  };
}
