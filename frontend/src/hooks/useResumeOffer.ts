import { useCallback, useEffect, useRef, useState } from "react";
import { useProfile } from "@/hooks/useProfile";
import { clearLastWatched, loadLastWatched, saveLastWatched, type LastWatched } from "@/lib/lastWatched";
import { stillPlayable } from "@/lib/playbackSession";
import type { PlayableKind, PlaybackSessionInfo } from "@/types";

/**
 * What was playing when the page was last left: offered in the corner until
 * it's resumed or dismissed, and remembered again as it plays.
 */
export function useResumeOffer(
  current: { kind: PlayableKind; id: string; session: PlaybackSessionInfo; startAt: number } | null,
  error: string | null,
  play: (kind: PlayableKind, id: string, options: { playlistId?: string; mediaFileId?: string }) => void,
) {
  const { profile } = useProfile();
  const profileId = profile?.id ?? null;
  const [resumable, setResumable] = useState<LastWatched | null>(() => loadLastWatched(profileId));
  const [resuming, setResuming] = useState(false);
  // What Resume was last pressed on, so its failure can ask whether it's gone.
  const resumed = useRef<LastWatched | null>(null);
  const lastWatched = useRef<{ sessionId: string; record: LastWatched } | null>(null);

  // Remember what's playing as soon as it starts; its reports keep it current.
  useEffect(() => {
    if (!current) return;
    const { session } = current;
    // The frame it was left on, until this session reports its own.
    const previous = lastWatched.current?.record ?? loadLastWatched(profileId);
    const record: LastWatched = {
      kind: current.kind,
      id: current.id,
      title: session.title,
      subtitle: session.subtitle,
      playlistId: session.playlist_id,
      mediaFileId: session.media_file?.id ?? null,
      position: current.startAt,
      duration: session.duration_seconds ?? 0,
      still: previous?.id === current.id ? previous.still : null,
    };
    lastWatched.current = { sessionId: session.id, record };
    saveLastWatched(profileId, record);
    setResumable(null);
    setResuming(false);
    resumed.current = null;
  }, [current, profileId]);
  const remember = useCallback(
    (sessionId: string, position: number, duration: number, still: string | null) => {
      const live = lastWatched.current;
      if (live?.sessionId !== sessionId) return;
      live.record = { ...live.record, position, duration: duration || live.record.duration, still: still ?? live.record.still };
      saveLastWatched(profileId, live.record);
    },
    [profileId],
  );
  const resume = useCallback(() => {
    if (!resumable) return;
    resumed.current = resumable;
    setResuming(true);
    play(resumable.kind, resumable.id, { playlistId: resumable.playlistId ?? undefined, mediaFileId: resumable.mediaFileId ?? undefined });
  }, [resumable, play]);
  const dismiss = useCallback(() => {
    clearLastWatched(profileId);
    setResumable(null);
  }, [profileId]);
  /** Closed (or finished): nothing to offer after a reload, and the closing player's last report mustn't bring it back. */
  const forget = useCallback(() => {
    lastWatched.current = null;
    clearLastWatched(profileId);
  }, [profileId]);
  // Offered only once the server says it can still be played: a title
  // purged since it was left, or whose files have all gone, is forgotten
  // rather than offered and then refused. Not hearing back offers it anyway.
  const [confirmed, setConfirmed] = useState<LastWatched | null>(null);
  useEffect(() => {
    if (!resumable) return;
    let live = true;
    void stillPlayable(resumable.kind, resumable.id).then((playable) => {
      if (!live) return;
      if (playable === false) dismiss();
      else setConfirmed(resumable);
    });
    return () => {
      live = false;
    };
  }, [resumable, dismiss]);
  useEffect(() => {
    if (!error) return;
    setResuming(false);
    // Gone since it was offered: forgotten, not left offering what won't play.
    const pressed = resumed.current;
    resumed.current = null;
    if (!pressed) return;
    void stillPlayable(pressed.kind, pressed.id).then((playable) => {
      if (playable !== false) return;
      if (loadLastWatched(profileId)?.id === pressed.id) clearLastWatched(profileId);
      setResumable((offered) => (offered === pressed ? null : offered));
    });
  }, [error, profileId]);

  return { resumable: confirmed === resumable ? resumable : null, resuming, remember, resume, dismiss, forget };
}
