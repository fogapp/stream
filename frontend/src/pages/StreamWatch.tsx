import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { ArrowLeft } from "lucide-react";
import { apiErrorMessage } from "@/api/client";
import { StreamControls } from "@/components/live/StreamControls";
import { playOrMute } from "@/components/player/audio";
import { failureMessage, reportPlayFailure } from "@/components/player/failure";
import { attachSource } from "@/components/player/source";
import { IconButton } from "@/components/ui/IconButton";
import { LoadingState } from "@/components/ui/PageState";
import { usePlaybackActions } from "@/hooks/usePlayback";
import { prefersNativeHls } from "@/lib/capabilities";
import { fromTv, tvLibraryPath } from "@/lib/tv";
import { liveHandoff } from "@/lib/liveHandoff";
import { createSession, releaseSession } from "@/lib/playbackSession";
import type { PlaybackSessionInfo } from "@/types";

/**
 * A camera or web stream, full screen (PROPOSAL §7.8). Stream relays it, so
 * this is live HLS like any other: it opens at live, pauses and goes back
 * within the few minutes the relay keeps, Jump to live catches up, and
 * when the source drops it says it's reconnecting and carries on when the
 * picture comes back — nothing to press.
 */
export function StreamWatch() {
  const { id = "" } = useParams();
  const navigate = useNavigate();
  const { close, registerLiveMain } = usePlaybackActions();
  const [session, setSession] = useState<PlaybackSessionInfo | null>(null);
  // Back to the library it came from: the TV's own, when it came from there.
  const back = useCallback(() => {
    const path = session?.back_path ?? "/";
    navigate(fromTv() ? tvLibraryPath(path) : path);
  }, [navigate, session]);

  // A VOD player in the corner stops: this is the screen now.
  useEffect(() => close(), [close]);
  // The main picture, for picture in picture: what an inset is over, and what a swap trades.
  const title = session?.title ?? null;
  useEffect(() => {
    if (title) return registerLiveMain({ kind: "stream", id, title });
  }, [id, title, registerLiveMain]);
  useEffect(() => {
    const key = `stream:${id}`;
    let cancelled = false;
    let made: PlaybackSessionInfo | null = null;
    setSession(null);
    // Swapped here from the inset: its session carries on (taken on the next
    // tick, so Strict Mode's rehearsal doesn't spend it).
    const start = window.setTimeout(() => {
      liveHandoff
        .receive(key)
        .then((handed) =>
          handed
            ? handed.session
            : createSession({ playable_type: "live_stream", playable_id: id }),
        )
        .then((answer) => {
          made = answer;
          if (cancelled) releaseSession(answer);
          else setSession(answer);
        })
        .catch((failure: unknown) => {
          if (cancelled) return;
          // Said in a toast, and back where it was opened from.
          reportPlayFailure(null, apiErrorMessage(failure, "This stream couldn't be played."));
          navigate(-1);
        });
    }, 0);
    return () => {
      cancelled = true;
      window.clearTimeout(start);
      if (!made) return;
      // Swapped into the inset: handed over, still playing.
      if (liveHandoff.isSwapping(key)) liveHandoff.put(key, made, 0);
      else releaseSession(made);
    };
  }, [id, navigate]);
  // Browser full screen on the whole page (with an inset up) ends with this page — unless it's swapping into the inset.
  useEffect(
    () => () => {
      if (document.fullscreenElement === document.documentElement && !liveHandoff.isSwapping()) void document.exitFullscreen().catch(() => undefined);
    },
    [],
  );

  if (!session) {
    return (
      <div data-theme="dark" className="fixed inset-0 z-50 flex items-center justify-center bg-background">
        <LoadingState label="Connecting…" />
      </div>
    );
  }
  return (
    <StreamPlayer
      streamId={id}
      session={session}
      onBack={back}
      onFailed={(message) => {
        reportPlayFailure(session.title, message);
        back();
      }}
    />
  );
}

/** The stream's own video element, its relay attached, under the controls. */
function StreamPlayer({
  streamId,
  session,
  onBack,
  onFailed,
}: {
  streamId: string;
  session: PlaybackSessionInfo;
  onBack: () => void;
  /** The relay couldn't be played at all (a dropped source reconnects by itself). */
  onFailed: (message: string) => void;
}) {
  const [video, setVideo] = useState<HTMLVideoElement | null>(null);
  const [picture, setPicture] = useState(false);
  const onFailedRef = useRef(onFailed);
  onFailedRef.current = onFailed;

  useEffect(() => {
    if (!video) return;
    const attached = attachSource(
      video,
      session.source,
      -1,
      prefersNativeHls(),
      { onFailure: (failure) => onFailedRef.current(failureMessage(failure)), onUnsupported: () => onFailedRef.current("This browser can't play streamed video.") },
      { live: true },
    );
    const shown = () => setPicture(true);
    // Once there's something to play: asked before hls.js has attached, the
    // play is cut short by its load, which isn't the browser refusing sound.
    const start = () => playOrMute(video);
    video.addEventListener("playing", shown);
    video.addEventListener("loadedmetadata", start, { once: true });
    return () => {
      video.removeEventListener("playing", shown);
      video.removeEventListener("loadedmetadata", start);
      attached.detach();
    };
  }, [video, session.source]);

  return (
    <div data-theme="dark" className="fixed inset-0 z-50 bg-background text-foreground">
      <video ref={setVideo} className="absolute inset-0 h-full w-full bg-background object-contain" playsInline />
      {!picture ? (
        <div className="absolute inset-0 flex items-center justify-center">
          <LoadingState label="Connecting…" />
        </div>
      ) : null}
      {video ? (
        <StreamControls
          video={video}
          session={session}
          onBack={onBack}
          playing={{ kind: "stream", id: streamId, title: session.title }}
          top={
            <div className="flex items-center gap-2 bg-gradient-to-b from-background/90 to-transparent px-4 pb-10 pt-4 sm:px-6">
              <IconButton label="Back (Escape)" size="lg" onClick={onBack}>
                <ArrowLeft className="h-5 w-5" aria-hidden />
              </IconButton>
              <div className="min-w-0">
                <p className="truncate text-lg font-semibold">{session.title}</p>
                {session.subtitle ? <p className="truncate text-sm text-muted">{session.subtitle}</p> : null}
              </div>
            </div>
          }
        />
      ) : null}
    </div>
  );
}
