/**
 * How big a video plays on its own page (PROPOSAL §5.4): in the page's
 * column, or at Full Width — across the page (YouTube's theater mode), or
 * over the whole window for someone who has asked Full Width to mean that.
 * Browser full screen is the player's own, on top of any of them.
 */
const PLAYER_SIZES = ["normal", "wide", "window"] as const;
export type PlayerSize = (typeof PLAYER_SIZES)[number];

const SIZE_KEY = "stream_player_size";
const FILL_WINDOW_KEY = "stream_full_width_fills_window";

/** Whether Full Width uses the full window (the player's Settings); off unless turned on. */
export function storedFillWindow(): boolean {
  try {
    return localStorage.getItem(FILL_WINDOW_KEY) === "true";
  } catch {
    return false;
  }
}

export function storeFillWindow(fill: boolean) {
  try {
    localStorage.setItem(FILL_WINDOW_KEY, String(fill));
  } catch {
    // A nicety.
  }
}

/** What Full Width is, by that setting. */
export function fullWidthSize(fillWindow: boolean): PlayerSize {
  return fillWindow ? "window" : "wide";
}

/** The size last left: Normal, or Full Width as the setting has it now. */
export function storedSize(): PlayerSize {
  try {
    const value = localStorage.getItem(SIZE_KEY);
    return PLAYER_SIZES.some((size) => size === value) && value !== "normal" ? fullWidthSize(storedFillWindow()) : "normal";
  } catch {
    return "normal";
  }
}

export function storeSize(size: PlayerSize) {
  try {
    localStorage.setItem(SIZE_KEY, size);
  } catch {
    // A nicety.
  }
}
