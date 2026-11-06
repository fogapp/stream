import { useEffect } from "react";
import { useParams, useSearchParams } from "react-router-dom";
import { usePlayback } from "@/hooks/usePlayback";
import { LoadingState } from "@/components/ui/PageState";
import type { PlayableKind } from "@/types";

/**
 * The full-screen player's route. It only asks the playback provider to
 * play this title; the player itself lives in the provider, so it survives
 * leaving this page as a mini-player.
 */
export function Watch() {
  const { kind = "movie", id = "" } = useParams();
  const [params] = useSearchParams();
  const { current, pending, preparing, play } = usePlayback();
  const playableKind: PlayableKind = kind === "episode" || kind === "extra" || kind === "video" || kind === "clip" ? kind : "movie";
  const fromStart = params.get("from") === "start";
  const version = params.get("version") ?? undefined;
  const playlist = params.get("playlist") ?? undefined;
  // A timestamp link ("1:30" in a description): start there.
  const at = Number(params.get("t"));
  const startAt = Number.isFinite(at) && at > 0 ? at : undefined;

  useEffect(() => {
    play(playableKind, id, { fromStart, mediaFileId: version, playlistId: playlist, startAt });
    // Only when the title changes: play() is a no-op for what's already playing.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [playableKind, id, version, playlist, startAt]);

  // A start that fails is said in a toast, and the provider takes the
  // viewer back off this route (components/player/failure.ts › leavePlayer).
  if (pending || current?.id !== id) {
    return (
      <div data-theme="dark" className="fixed inset-0 z-50 flex items-center justify-center bg-background">
        <LoadingState label={preparing ? "Getting this ready to stream…" : "Starting…"} />
      </div>
    );
  }
  // The provider's player is on screen.
  return null;
}
