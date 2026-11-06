import { useCallback, useEffect, useState, type ReactNode } from "react";
import { RotateCcw } from "lucide-react";
import { IconButton } from "@/components/ui/IconButton";
import { FullscreenButton, LiveBadge, PlayPauseButton, ScrubBar, VolumeControl } from "@/components/player/controls";
import { usePlayhead, usePlayheadValue, type Playhead } from "@/components/player/playhead";
import { useAutoHide } from "@/components/player/useAutoHide";
import { usePlayerVolume } from "@/components/player/usePlayerVolume";
import { PipPicker } from "@/components/pip/PipPicker";
import { usePlayback } from "@/hooks/usePlayback";
import { toggleFullscreen as fullscreenToggle, type PipSource } from "@/lib/pip";
import { cn } from "@/lib/cn";
import { formatClock } from "@/lib/format";
import { notAShortcut } from "@/lib/keys";
import { beaconProgress, postProgress } from "@/lib/playbackSession";
import { useDocumentFullscreen } from "@/hooks/useDocumentFullscreen";
import { viewerMuted } from "@/lib/volume";
import type { LiveRelayState, PlaybackSessionInfo } from "@/types";

const REPORT_EVERY_MS = 10_000;
/** Within this many seconds of the newest picture counts as live. */
const LIVE_SLACK = 12;
/** Waiting this long for the next picture is the source's trouble, not a hiccup. */
const RECONNECTING_AFTER_MS = 4_000;

/**
 * The controls over a camera or web stream (PROPOSAL §7.8), for a video
 * element already playing its relay: live HLS, so it pauses and goes back
 * within the few minutes the relay keeps, Jump to live catches up, and when
 * the source drops it says it's reconnecting and carries on when the
 * picture comes back — nothing to press. `top` is what sits above the
 * picture: a Back button, or a Grid channel's bar.
 */
export function StreamControls({
  video,
  session,
  top,
  keys = true,
  onBack,
  playing: nowPlaying,
}: {
  video: HTMLVideoElement;
  session: PlaybackSessionInfo;
  top: ReactNode;
  /** Whether its keyboard shortcuts are live. */
  keys?: boolean;
  onBack: () => void;
  /** What this is, for the picture-in-picture picker: the stream, or the channel showing it. */
  playing: PipSource;
}) {
  const [playing, setPlaying] = useState(!video.paused);
  // How far behind live and how much the relay keeps, outside React state: a
  // timeupdate re-renders the bar and the badge, not these controls.
  const behind = usePlayhead(0);
  const span = usePlayhead(0);
  // Quiet while the inset's sound was chosen (picture in picture).
  const { mainSilenced, hearMain } = usePlayback();
  const { volume, quiet, changeVolume, toggleMute } = usePlayerVolume({
    element: video,
    silenced: mainSilenced,
    onUnsilence: hearMain,
    // The channel deck has it muted already, when the viewer does.
    startMuted: () => video.muted || viewerMuted(),
  });
  const fullscreen = useDocumentFullscreen();
  const { shown: controls, reveal, show: showControls } = useAutoHide(() => video.paused);
  const [failure, setFailure] = useState<string | null>(null);
  const [relay, setRelay] = useState<{ state: LiveRelayState; message: string | null } | null>(null);
  const [waitingSince, setWaitingSince] = useState<number | null>(null);
  const [now, setNow] = useState(() => performance.now());

  // Where live is: the end of what can be played (the playlist's newest segment).
  const edge = useCallback(() => {
    if (video.seekable.length === 0) return null;
    return { start: video.seekable.start(0), end: video.seekable.end(video.seekable.length - 1) };
  }, [video]);

  useEffect(() => {
    const onTime = () => {
      const range = edge();
      if (!range) return;
      behind.set(Math.max(range.end - video.currentTime, 0));
      span.set(Math.max(range.end - range.start, 0));
    };
    const onPlay = () => setPlaying(true);
    const onPause = () => {
      setPlaying(false);
      showControls();
    };
    const onWaiting = () => {
      if (!video.paused && !video.seeking) setWaitingSince(performance.now());
    };
    const onPlaying = () => {
      setWaitingSince(null);
      setPlaying(true);
    };
    const onError = () => {
      if (!video.src) return;
      setFailure("This browser couldn't play this stream. The admin page Playback decisions has the details.");
    };
    video.addEventListener("timeupdate", onTime);
    video.addEventListener("play", onPlay);
    video.addEventListener("pause", onPause);
    video.addEventListener("waiting", onWaiting);
    video.addEventListener("playing", onPlaying);
    video.addEventListener("error", onError);
    return () => {
      video.removeEventListener("timeupdate", onTime);
      video.removeEventListener("play", onPlay);
      video.removeEventListener("pause", onPause);
      video.removeEventListener("waiting", onWaiting);
      video.removeEventListener("playing", onPlaying);
      video.removeEventListener("error", onError);
    };
  }, [video, edge, showControls, behind, span]);

  // Where the viewer is, now and then, which keeps the session open; the
  // answer says how the relay is doing.
  const report = useCallback(
    (ended = false) => {
      const body = { position: Number.isFinite(video.currentTime) ? video.currentTime : 0, ended };
      if (ended && beaconProgress(session.progress_url, body)) return;
      void postProgress<{ relay?: { state: LiveRelayState; message: string | null } | null }>(session.progress_url, body).then((answer) => setRelay(answer?.relay ?? null));
    },
    [video, session.progress_url],
  );
  // Every few seconds while it waits: a stutter changes the pace once,
  // not a post per waiting and playing.
  const waiting = waitingSince !== null;
  useEffect(() => {
    report();
    const timer = window.setInterval(() => report(), waiting ? 2_000 : REPORT_EVERY_MS);
    return () => window.clearInterval(timer);
  }, [report, waiting]);
  useEffect(() => {
    const onHide = () => report(true);
    window.addEventListener("pagehide", onHide);
    return () => window.removeEventListener("pagehide", onHide);
  }, [report]);
  useEffect(() => {
    if (waitingSince === null) return;
    const timer = window.setInterval(() => setNow(performance.now()), 500);
    return () => window.clearInterval(timer);
  }, [waitingSince]);

  useEffect(() => reveal(), [reveal]);

  const seekTo = useCallback(
    (seconds: number) => {
      const range = edge();
      if (!range) return;
      video.currentTime = Math.min(Math.max(seconds, range.start), range.end);
      reveal();
    },
    [video, edge, reveal],
  );
  const jumpToLive = useCallback(() => {
    const range = edge();
    if (range) video.currentTime = Math.max(range.end - 3, range.start);
    void video.play().catch(() => undefined);
  }, [video, edge]);
  const togglePlay = useCallback(() => {
    if (video.paused) void video.play().catch(() => undefined);
    else video.pause();
    reveal();
  }, [video, reveal]);
  // Full screen is the whole page, which this fills anyway: an inset opened over it shows too.
  const toggleFullscreen = useCallback(() => fullscreenToggle(document.documentElement), []);

  useEffect(() => {
    if (!keys) return;
    const onKey = (event: KeyboardEvent) => {
      if (notAShortcut(event)) return;
      switch (event.key) {
        case " ":
        case "k":
          togglePlay();
          break;
        case "j":
        case "ArrowLeft":
          seekTo(video.currentTime - 10);
          break;
        case "l":
        case "ArrowRight":
          seekTo(video.currentTime + 10);
          break;
        case "End":
          jumpToLive();
          break;
        case "m":
          toggleMute();
          break;
        case "f":
          toggleFullscreen();
          break;
        case "Escape":
          if (!document.fullscreenElement) onBack();
          break;
        default:
          return;
      }
      event.preventDefault();
      reveal();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [keys, video, togglePlay, seekTo, jumpToLive, toggleFullscreen, onBack, reveal, toggleMute]);

  const stuck = waitingSince !== null && now - waitingSince > RECONNECTING_AFTER_MS;
  const reconnecting = relay?.state === "reconnecting" || stuck;
  const hidden = !controls && playing && !reconnecting;

  return (
    <div
      className={cn("absolute inset-0 flex flex-col justify-between transition-opacity duration-300", hidden ? "cursor-none opacity-0" : "opacity-100")}
      onMouseMove={reveal}
      onTouchStart={reveal}
      onClick={(event) => {
        if (event.target === event.currentTarget) togglePlay();
      }}
      onDoubleClick={(event) => {
        if (event.target === event.currentTarget) toggleFullscreen();
      }}
    >
      {top}

      {failure ? (
        <div className="mx-auto max-w-md rounded-[var(--radius-card)] bg-surface px-5 py-4 text-center text-sm">{failure}</div>
      ) : reconnecting ? (
        <div role="status" className="mx-auto max-w-md rounded-[var(--radius-card)] bg-surface/90 px-5 py-4 text-center text-sm">
          <p className="font-medium">Reconnecting…</p>
          {relay?.message ? <p className="mt-1 text-muted">{relay.message}</p> : null}
        </div>
      ) : null}

      <div className="space-y-3 bg-gradient-to-t from-background/95 via-background/70 to-transparent px-4 pb-4 pt-16 sm:px-6">
        <RelayBar
          behind={behind}
          span={span}
          onFraction={(fraction) => {
            const range = edge();
            if (range) seekTo(range.start + fraction * (range.end - range.start));
          }}
          onStep={(seconds) => seekTo(video.currentTime + seconds)}
        />
        <div className="flex items-center gap-1 sm:gap-2">
          <PlayPauseButton playing={playing} onToggle={togglePlay} />
          <IconButton label="Back 10 seconds (j)" size="lg" onClick={() => seekTo(video.currentTime - 10)}>
            <RotateCcw className="h-5 w-5" aria-hidden />
          </IconButton>
          <VolumeControl quiet={quiet} volume={volume} onToggleMute={toggleMute} onVolume={changeVolume} />
          <span className="flex-1" />
          <RelayBadge behind={behind} onJump={jumpToLive} />
          <PipPicker playing={nowPlaying} />
          <FullscreenButton fullscreen={fullscreen} onToggle={toggleFullscreen} />
        </div>
      </div>
    </div>
  );
}

/** Live, or how far behind it: all that re-renders as the relay moves, with the bar. */
function RelayBadge({ behind, onJump }: { behind: Playhead; onJump: () => void }) {
  const seconds = usePlayheadValue(behind, (value) => Math.floor(value));
  return <LiveBadge atLive={seconds < LIVE_SLACK} behind={seconds} onJump={onJump} testId="live-badge" />;
}

/** The few minutes the relay keeps, and where the viewer is in them. */
function RelayBar({
  behind,
  span,
  onFraction,
  onStep,
}: {
  behind: Playhead;
  span: Playhead;
  onFraction: (fraction: number) => void;
  onStep: (seconds: number) => void;
}) {
  const seconds = usePlayheadValue(behind, (value) => value);
  const kept = usePlayheadValue(span, (value) => value);
  const position = kept > 0 ? Math.min(Math.max((kept - seconds) / kept, 0), 1) * 100 : 100;
  return (
    <ScrubBar
      label="Position behind live"
      max={kept}
      now={kept - seconds}
      text={seconds < LIVE_SLACK ? "Live" : `${formatClock(seconds)} behind live`}
      onFraction={onFraction}
      onStep={onStep}
    >
      <div className="absolute inset-y-0 left-0 rounded-full bg-primary" style={{ width: `${position}%` }} />
    </ScrubBar>
  );
}
