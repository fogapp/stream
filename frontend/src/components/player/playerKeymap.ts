export const SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2] as const;

/** The speed one step slower or faster, staying on the list's ends. */
export function stepSpeed(value: number, step: 1 | -1): number {
  const index = SPEEDS.indexOf(value as (typeof SPEEDS)[number]);
  return SPEEDS[step > 0 ? Math.min(index + 1, SPEEDS.length - 1) : Math.max(index - 1, 0)] ?? 1;
}

/** What the main player's keys can do, with the player as it is now. */
export interface PlayerKeyActions {
  element: HTMLVideoElement;
  /** Where the viewer is, counting a seek that hasn't landed yet. */
  position: () => number;
  seekTo: (seconds: number) => void;
  togglePlay: () => void;
  volume: number;
  changeVolume: (value: number) => void;
  /** m: the volume stays, so turning it up from here is from where it was. */
  mute: () => void;
  changeRate: (step: 1 | -1) => void;
  frameRate: number | null | undefined;
  toggleSubtitles: () => void;
  /** i: back to the title, where that's a place to go. */
  info: (() => void) | null;
  /** t: where there's a choice of size. */
  toggleSize: (() => void) | null;
  /** N: the next item, if there is one. */
  next: (() => void) | null;
  toggleKeys: () => void;
  toggleFullscreen: () => void;
  toggleStats: () => void;
  toggleRelated: () => void;
  /** Whatever Escape closes first; false when it's nothing of this player's. */
  escape: () => boolean;
}

/** Runs one key; false when it wasn't the player's, so the page keeps it. */
export function runPlayerKey(key: string, actions: PlayerKeyActions): boolean {
  const { element, position, seekTo, volume, changeVolume } = actions;
  switch (key) {
    case " ":
    case "k":
      actions.togglePlay();
      return true;
    case "j":
      seekTo(position() - 10);
      return true;
    case "l":
      seekTo(position() + 10);
      return true;
    case "ArrowLeft":
      seekTo(position() - 5);
      return true;
    case "ArrowRight":
      seekTo(position() + 5);
      return true;
    case "ArrowUp":
      changeVolume(volume + 0.05);
      return true;
    case "ArrowDown":
      changeVolume(volume - 0.05);
      return true;
    case "<":
      actions.changeRate(-1);
      return true;
    case ">":
      actions.changeRate(1);
      return true;
    case ",":
    case ".": {
      if (!element.paused) return false;
      // One frame at the file's own rate (24 when it doesn't say).
      const rate = actions.frameRate && actions.frameRate > 0 ? actions.frameRate : 24;
      seekTo(position() + (key === "." ? 1 : -1) / rate);
      return true;
    }
    case "c":
      actions.toggleSubtitles();
      return true;
    case "i":
      if (!actions.info) return false;
      actions.info();
      return true;
    case "t":
      if (!actions.toggleSize) return false;
      actions.toggleSize();
      return true;
    case "N":
      actions.next?.();
      return true;
    case "?":
      actions.toggleKeys();
      return true;
    case "m":
      actions.mute();
      return true;
    case "f":
      actions.toggleFullscreen();
      return true;
    case "s":
      actions.toggleStats();
      return true;
    case "r":
      actions.toggleRelated();
      return true;
    case "Escape":
      return actions.escape();
    default:
      if (/^[0-9]$/.test(key) && element.duration) {
        seekTo((Number(key) / 10) * element.duration);
        return true;
      }
      return false;
  }
}
