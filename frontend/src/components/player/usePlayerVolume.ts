import { useCallback, useEffect, useState } from "react";
import { rememberMuted, rememberVolume, storedVolume, viewerMuted } from "@/lib/volume";

/**
 * A player's volume: the one the person chose (full, or the last they set),
 * whether they muted it, and what the element is set to because of both.
 * `silenced` is quiet because the other picture's sound was chosen, whatever
 * its own volume says; turned up then, `onUnsilence` says it's wanted too.
 * `scale` is the levelling a title's loudness asks for: the element gets the
 * chosen volume times it, so steps are taken from the chosen one.
 * `startMuted` is for a player taking over an element that's already quiet.
 */
export function usePlayerVolume({
  element,
  scale = 1,
  silenced = false,
  onUnsilence,
  startMuted = viewerMuted,
}: {
  element: HTMLVideoElement | null;
  scale?: number;
  silenced?: boolean;
  onUnsilence?: () => void;
  startMuted?: () => boolean;
}) {
  const [volume, setVolume] = useState(storedVolume);
  const [muted, setMuted] = useState(startMuted);
  const quiet = muted || silenced;

  useEffect(() => {
    if (!element) return;
    element.volume = Math.min(1, (quiet ? 0 : volume) * scale);
    // Truly muted, not just silent: it's what lets a browser autoplay.
    element.muted = quiet;
  }, [element, volume, quiet, scale]);

  const changeVolume = useCallback(
    (value: number) => {
      const next = Math.min(Math.max(value, 0), 1);
      setVolume(next);
      setMuted(next === 0);
      rememberMuted(next === 0);
      // Turned up while the other picture has the sound: both, then.
      if (next > 0 && silenced) onUnsilence?.();
      rememberVolume(next);
    },
    [silenced, onUnsilence],
  );
  const toggleMute = useCallback(() => changeVolume(quiet ? volume || storedVolume() : 0), [changeVolume, quiet, volume]);

  return { volume, muted, setMuted, quiet, changeVolume, toggleMute };
}
