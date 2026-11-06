export const VOLUME_KEY = "stream_volume";

/** A mute the viewer chose carries to the next item or program, and on until they unmute. */
let mutedByViewer = false;

export function viewerMuted(): boolean {
  return mutedByViewer;
}

export function rememberMuted(muted: boolean) {
  mutedByViewer = muted;
}

/** The volume last chosen in a player, on this device; full until one is. */
export function storedVolume(): number {
  try {
    const value = Number(localStorage.getItem(VOLUME_KEY));
    return Number.isFinite(value) && value > 0 && value <= 1 ? value : 1;
  } catch {
    return 1;
  }
}

/** Kept for the next player on this device; silence isn't a volume to come back to. */
export function rememberVolume(value: number) {
  if (value <= 0) return;
  try {
    localStorage.setItem(VOLUME_KEY, String(value));
  } catch {
    // Remembering the volume is a nicety.
  }
}
