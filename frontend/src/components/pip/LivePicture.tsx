import { useEffect, useRef, useState } from "react";
import { api, ApiError, apiErrorMessage } from "@/api/client";
import { playOrMute } from "@/components/player/audio";
import { attachSource } from "@/components/player/source";
import { FrameCorners } from "@/components/player/FrameCorners";
import { useMiniFrame, type InsetArea } from "@/components/player/miniFrame";
import { PipControls } from "@/components/pip/PipControls";
import { LoadingState } from "@/components/ui/PageState";
import { prefersNativeHls } from "@/lib/capabilities";
import { cn } from "@/lib/cn";
import { clockSkew, gapWait, liveOffset } from "@/lib/live";
import { liveHandoff } from "@/lib/liveHandoff";
import { createSession, postProgress, readyInMs, releaseSession } from "@/lib/playbackSession";
import { handoffKey, swapOnDoubleClick, type PipAudio, type PipSource } from "@/lib/pip";
import { storedVolume } from "@/lib/volume";
import type { PlaybackSessionInfo } from "@/types";

type LiveSource = Extract<PipSource, { kind: "station" | "stream" }>;

const REPORT_EVERY_MS = 10_000;
/** A channel that won't tune is tried again this often, saying so meanwhile. */
const RETRY_MS = 5_000;

function tuneBody(source: LiveSource) {
  const body = source.kind === "station" ? { station_id: source.stationId } : { playable_type: "live_stream", playable_id: source.id };
  return body;
}

/**
 * A Grid channel or a camera in the inset (picture in picture): tuned as a
 * play of its own — or handed over from its page by a swap, still playing
 * and as far behind live as it was — and handed back to its page the same
 * way. A channel goes on to whatever airs next when its program ends; a
 * stream's relay keeps it at live. It reports like any play, so the server
 * keeps its session (and a camera's relay) open.
 */
export function LivePicture({
  source,
  audio,
  heard,
  onAudio,
  onSwap,
  onClose,
  area,
}: {
  source: LiveSource;
  audio: PipAudio;
  heard: boolean;
  onAudio: (audio: PipAudio) => void;
  onSwap: () => void;
  onClose: () => void;
  /** The main picture it's kept inside; none: the window. */
  area: InsetArea | null;
}) {
  const frame = useMiniFrame("pip", area?.box ?? null);
  const video = useRef<HTMLVideoElement>(null);
  const [session, setSession] = useState<PlaybackSessionInfo | null>(null);
  const [picture, setPicture] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  // Bumped to tune again: the program ended, or a gap or a failure waited out.
  const [tuning, setTuning] = useState(0);
  const key = handoffKey(source);
  const heardRef = useRef(heard);
  heardRef.current = heard;

  useEffect(() => {
    const element = video.current;
    if (!element) return;
    element.volume = storedVolume();
    element.muted = !heard;
  }, [heard]);

  useEffect(() => {
    const element = video.current;
    if (!element) return;
    let tuned: PlaybackSessionInfo | null = null;
    let skew = 0;
    let detach: (() => void) | null = null;
    let cancelled = false;
    let retry: number | undefined;
    // One at a time: a failure's sooner tune replaces the program's end, rather than leaving it to fire as well.
    const again = (delay: number) => {
      window.clearTimeout(retry);
      retry = window.setTimeout(() => setTuning((count) => count + 1), delay);
    };
    let onMetadata: (() => void) | null = null;
    setPicture(false);
    // Taken on the next tick: Strict Mode's rehearsal unmounts at once, and mustn't spend the handoff.
    const start = window.setTimeout(() => {
      let handed: Awaited<ReturnType<typeof liveHandoff.receive>> = null;
      liveHandoff
        .receive(key)
        .then((received) => {
          handed = received;
          return received ? received.session : createSession(tuneBody(source));
        })
        .then((answer) => {
          if (cancelled) {
            releaseSession(answer);
            return;
          }
          tuned = answer;
          setSession(answer);
          setMessage(null);
          // Handed from a channel's page, it was a play there; from the guide, on standby.
          if (handed) void api.post(`/playback_sessions/${answer.id}/watch`, { position: answer.resume_at }).catch(() => undefined);
          const live = answer.live;
          skew = handed ? handed.skew : live ? clockSkew(live.server_now) : 0;
          const stream = Boolean(answer.live_stream);
          const behind = handed?.behind ?? 0;
          // Seconds into the file: a part of a program starts partway in. A stream opens at its newest.
          const at = () => (stream ? -1 : live ? Math.max(live.media_start + liveOffset(live, Date.now() + skew) - behind, live.media_start) : answer.resume_at);
          const nativeHls = answer.source.kind === "hls" && prefersNativeHls();
          element.muted = !heardRef.current;
          detach = attachSource(
            element,
            answer.source,
            at(),
            nativeHls,
            {
              onFailure: ({ cause: failure }) => {
                setPicture(false);
                setMessage(`It stopped: ${failure.slice(0, 120)}`);
                again(RETRY_MS);
              },
              onUnsupported: () => setMessage("This browser can't play streamed video."),
            },
            { maxBufferLength: 20, live: stream },
          ).detach;
          onMetadata = () => {
            const target = at();
            if (!stream && target > 0 && target < element.duration - 0.5) element.currentTime = target;
            playOrMute(element);
          };
          element.addEventListener("loadedmetadata", onMetadata, { once: true });
          // The program's end (a game's slot's, too): on to what airs next (as far behind live as this was).
          if (live) again(Math.max(Date.parse(live.ends_at) - (Date.now() + skew) + behind * 1000, 1_000));
        })
        .catch((failure: unknown) => {
          if (cancelled) return;
          if (failure instanceof ApiError && failure.status === 409) {
            const wait = gapWait(failure.message, failure.retryAfter);
            setMessage(wait !== null ? "Between programs." : apiErrorMessage(failure, "This can't play here right now."));
            again(wait ?? readyInMs(failure) ?? RETRY_MS * 6);
            return;
          }
          setMessage(apiErrorMessage(failure, "This couldn't be tuned."));
          if (!(failure instanceof ApiError && failure.status >= 400 && failure.status < 500)) again(RETRY_MS);
        });
    }, 0);

    // Reported like any play: the server keeps the session (and a camera's relay) going.
    const report = window.setInterval(() => {
      if (!tuned) return;
      void postProgress(tuned.progress_url, { position: Number.isFinite(element.currentTime) ? element.currentTime : 0, ended: false });
    }, REPORT_EVERY_MS);

    return () => {
      cancelled = true;
      window.clearTimeout(start);
      window.clearTimeout(retry);
      window.clearInterval(report);
      const live = tuned?.live;
      const behind = tuned && live && !tuned.live_stream ? Math.max(live.media_start + liveOffset(live, Date.now() + skew) - element.currentTime, 0) : 0;
      if (onMetadata) element.removeEventListener("loadedmetadata", onMetadata);
      detach?.();
      if (!tuned) return;
      // Swapped onto its page: handed over, still playing. Otherwise it's done.
      if (liveHandoff.isSwapping(key)) liveHandoff.put(key, tuned, skew, behind);
      else releaseSession(tuned);
    };
    // The source is the key's: a new title for the same channel isn't a new tune.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, tuning]);

  // A channel says what's on it.
  const subtitle = source.kind === "station" ? (session?.title ?? null) : null;
  const title = source.kind === "station" ? `${source.number} ${source.title}` : source.title;

  return (
    <div
      data-theme="dark"
      data-testid="pip"
      className={cn(
        "group cursor-grab touch-none select-none overflow-hidden rounded-[var(--radius-card)] bg-background text-foreground shadow-xl ring-1 ring-border",
        // Over a picture in a page, it scrolls with the page under the header.
        area?.page ? "absolute z-[15]" : "fixed z-[60]",
        frame.dragging && "cursor-grabbing",
      )}
      style={{ left: frame.box.left, top: frame.box.top, width: frame.box.width, height: frame.box.height }}
      {...frame.frameProps}
      tabIndex={0}
      onKeyDown={frame.onKeyDown}
      role="region"
      aria-label={`Picture in picture: ${title}`}
      onDoubleClick={(event) => swapOnDoubleClick(event, onSwap)}
    >
      <video ref={video} playsInline draggable={false} muted={!heard} className="h-full w-full object-contain" onPlaying={() => setPicture(true)} />
      {!picture ? (
        <div className="pointer-events-none absolute inset-0 flex items-center justify-center p-3 text-center text-sm">
          {message ? <p className="text-muted">{message}</p> : <LoadingState label="Tuning…" />}
        </div>
      ) : null}
      <PipControls title={title} subtitle={subtitle} audio={audio} heard={heard} onAudio={onAudio} onSwap={onSwap} onClose={onClose} />
      <FrameCorners cornerProps={frame.cornerProps} />
    </div>
  );
}
