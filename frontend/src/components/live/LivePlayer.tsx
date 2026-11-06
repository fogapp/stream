import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { RotateCcw, SkipBack } from "lucide-react";
import { ChannelBar } from "@/components/live/ChannelBar";
import { PipPicker } from "@/components/pip/PipPicker";
import { usePlayback } from "@/hooks/usePlayback";
import { FullscreenButton, LiveBadge, PlayPauseButton, ScrubBar, SubtitleMenu, VolumeControl } from "@/components/player/controls";
import { AtPlayhead, usePlayhead, usePlayheadValue, type Playhead } from "@/components/player/playhead";
import { initialSubtitle, rememberSubtitle, subtitleLabel, useSubtitles } from "@/components/player/subtitles";
import { useAutoHide } from "@/components/player/useAutoHide";
import { usePlayerVolume } from "@/components/player/usePlayerVolume";
import { useSeekBatch } from "@/components/player/useSeekBatch";
import { usePlaybackTiming } from "@/components/player/timing";
import { IconButton } from "@/components/ui/IconButton";
import { cn } from "@/lib/cn";
import { formatClock } from "@/lib/format";
import { notAShortcut } from "@/lib/keys";
import { clockTime, liveOffset, stuckAtEnd } from "@/lib/live";
import { liveHandoff } from "@/lib/liveHandoff";
import { livePlace } from "@/lib/livePlace";
import { beaconProgress, postEvents, postProgress } from "@/lib/playbackSession";
import { toggleFullscreen as fullscreenToggle } from "@/lib/pip";
import { useDocumentFullscreen } from "@/hooks/useDocumentFullscreen";
import { useNow } from "@/hooks/useNow";
import type { EndedVia } from "@/components/live/channelDeck";
import type { Airing, PlaybackSessionInfo } from "@/types";

const REPORT_EVERY_MS = 10_000;
/** Within this many seconds of live counts as live. */
const LIVE_SLACK = 8;
/** How often the picture is checked for having stuck at the program's end. */
const WATCHDOG_MS = 1_000;

/**
 * The controls over a Grid channel (PROPOSAL §7.7), for the video the
 * page has on screen: the airing plays from where live is, pausing and
 * rewinding within it is allowed (then it says how far behind live it is),
 * Restart goes back to its beginning, Jump to live catches up, and it can
 * never run ahead of live. Channel changes belong to the page around it.
 */
export function LivePlayer({
  video,
  session,
  airing,
  next,
  timeZone,
  skew,
  keys,
  onEnded,
  onRestart,
  onBack,
  onChannel,
  onGuide,
  onNow,
  nowOpen,
  bannerKey,
}: {
  video: HTMLVideoElement;
  session: PlaybackSessionInfo;
  airing: Airing | null;
  next: Airing | null;
  timeZone: string;
  /** Add to Date.now() for the server's clock. */
  skew: number;
  /** Whether its keyboard shortcuts are live (not while the mini guide is open). */
  keys: boolean;
  /** This airing has finished playing; `behind` is how far behind live it was, `via` what noticed. */
  onEnded: (behind: number, via: EndedVia) => void;
  /** Back to the program's beginning — its first part, when it airs in parts. */
  onRestart: () => void;
  onBack: () => void;
  onChannel: (step: 1 | -1) => void;
  onGuide: () => void;
  onNow: () => void;
  nowOpen: boolean;
  /** Changes whenever the channel banner should show again. */
  bannerKey: string;
}) {
  const live = session.live;
  const [playing, setPlaying] = useState(!video.paused);
  // Where it is, outside React state: a timeupdate re-renders the bar and the
  // clock, not these controls and their menus (the main player's way).
  const playhead = usePlayhead(video.currentTime);
  // Quiet while the inset's sound was chosen (picture in picture).
  const { mainSilenced, hearMain } = usePlayback();
  const { volume, quiet, changeVolume, toggleMute } = usePlayerVolume({ element: video, silenced: mainSilenced, onUnsilence: hearMain });
  // Left for the guide, its preview carries on as loud as this (or as quiet).
  useEffect(() => liveHandoff.heard(quiet ? 0 : volume), [volume, quiet]);
  const fullscreen = useDocumentFullscreen();
  const { shown: controls, reveal, show: showControls } = useAutoHide(() => video.paused);
  const [failure, setFailure] = useState<string | null>(null);
  // A picture subtitle has to be burned in, which restarts a stream: not one a channel can offer.
  const pickable = useMemo(() => session.subtitles.filter((track) => !track.burn), [session.subtitles]);
  const [subtitleId, setSubtitleId] = useState<string | null>(() => initialSubtitle(session.subtitles));
  const subtitle = session.subtitles.find((track) => track.id === subtitleId) ?? null;
  useSubtitles(video, subtitle, session.fonts);

  // What the viewer felt — a seek's wait, a stall — for the Playback
  // decisions page, as the main player reports them.
  const note = useCallback(
    (kind: "seek" | "stall", detail: Record<string, number | boolean>) => postEvents(session.events_url, [{ kind, position: video.currentTime, detail }]),
    [video, session.events_url],
  );
  usePlaybackTiming(video, null, (kind, _position, detail) => (kind === "seek" ? note("seek", { ...detail }) : undefined), true);

  const liveStart = live?.starts_at;
  const liveEnd = live?.ends_at;
  const span = useMemo(() => (liveStart && liveEnd ? { starts_at: liveStart, ends_at: liveEnd } : null), [liveStart, liveEnd]);
  // Times here are seconds into the file; a part of a program starts partway in.
  const base = live?.media_start ?? 0;
  const partEnd = live?.media_end ?? null;
  const length = span ? (Date.parse(span.ends_at) - Date.parse(span.starts_at)) / 1000 : (session.duration_seconds ?? 0);
  /** Where live is, in seconds into the file, at a moment on the server's clock. */
  const liveAt = useCallback((at: number) => base + (span ? liveOffset(span, at) : length), [base, span, length]);

  const report = useCallback(
    (ended = false) => {
      if (!Number.isFinite(video.currentTime)) return;
      // Behind live: where a reload of the page picks this channel up (livePlace).
      if (live && span) {
        const behindNow = base + liveOffset(span, Date.now() + skew) - video.currentTime;
        if (behindNow > LIVE_SLACK) livePlace.save({ stationId: live.station_id, airingId: live.airing_id, position: video.currentTime, endsAt: live.ends_at });
        else livePlace.clear(live.station_id);
      }
      const body = { position: video.currentTime, ended };
      if (ended && beaconProgress(session.progress_url, body)) return;
      void postProgress(session.progress_url, body);
    },
    [video, session.progress_url, live, span, base, skew],
  );

  useEffect(() => {
    reveal();
  }, [bannerKey, reveal]);

  // Seeks from keys and buttons land together, as in the main player
  // (SEEK_SETTLE_MS): every seek behind what's buffered starts the
  // transcoder again, so a run of presses asks it for one place.
  const { position, seeking, seek } = useSeekBatch(useCallback(() => video, [video]));

  // The element belongs to the page; this listens to it while on screen.
  const ended = useRef(onEnded);
  ended.current = onEnded;
  useEffect(() => {
    let finished = false;
    const finish = (via: EndedVia) => {
      if (finished) return;
      finished = true;
      report(true);
      ended.current(Math.max((Date.now() + skew - Date.parse(liveEnd ?? new Date().toISOString())) / 1000, 0), via);
    };
    const onTime = () => {
      // The bar shows a seek that hasn't landed yet where it's going.
      if (!seeking()) playhead.set(video.currentTime);
      // A part ends partway through its file.
      if (partEnd !== null && video.currentTime >= partEnd - 0.05) {
        video.pause();
        finish("part");
      }
    };
    const onPlay = () => {
      setPlaying(true);
      reveal();
    };
    const onPause = () => {
      setPlaying(false);
      showControls();
      report();
    };
    const onEnd = () => finish("ended");
    // A stream that never says it ended — its last segment never came, or
    // the browser paused at the end — would leave the last frame up for
    // good: a picture stuck at the end is the end (stuckAtEnd).
    // (It may also have ended before these controls came up.)
    let lastPosition = video.currentTime;
    let movedAt = performance.now();
    const watchdog = window.setInterval(() => {
      if (video.ended) {
        finish("ended");
        return;
      }
      if (video.currentTime !== lastPosition || video.seeking || video.paused) {
        lastPosition = video.currentTime;
        movedAt = performance.now();
      }
      const end = Math.min(partEnd ?? Infinity, base + length, Number.isFinite(video.duration) ? video.duration : Infinity);
      if (stuckAtEnd({ position: video.currentTime, end, stuckMs: performance.now() - movedAt, paused: video.paused })) finish("watchdog");
    }, WATCHDOG_MS);
    let stalledAt: number | null = null;
    const onWaiting = () => {
      if (!video.paused && !video.seeking) stalledAt = performance.now();
    };
    const onPlaying = () => {
      const began = stalledAt;
      stalledAt = null;
      if (began !== null && performance.now() - began > 500) note("stall", { seconds: Math.round(performance.now() - began) / 1000 });
    };
    const onError = () => {
      if (session.source.kind === "hls" && !video.src) return;
      setFailure("This browser couldn't play this program. The admin page Playback decisions has the details.");
    };
    video.addEventListener("timeupdate", onTime);
    video.addEventListener("play", onPlay);
    video.addEventListener("pause", onPause);
    video.addEventListener("ended", onEnd);
    video.addEventListener("error", onError);
    video.addEventListener("waiting", onWaiting);
    video.addEventListener("playing", onPlaying);
    setPlaying(!video.paused);
    return () => {
      window.clearInterval(watchdog);
      video.removeEventListener("timeupdate", onTime);
      video.removeEventListener("play", onPlay);
      video.removeEventListener("pause", onPause);
      video.removeEventListener("ended", onEnd);
      video.removeEventListener("error", onError);
      video.removeEventListener("waiting", onWaiting);
      video.removeEventListener("playing", onPlaying);
    };
  }, [video, reveal, showControls, report, note, skew, liveEnd, partEnd, base, length, session.source.kind, playhead, seeking]);

  useEffect(() => {
    if (!playing) return;
    const timer = window.setInterval(() => report(), REPORT_EVERY_MS);
    return () => window.clearInterval(timer);
  }, [playing, report]);
  // Closing the tab ends the play. Leaving the screen doesn't: the channel
  // deck owns the session, and keeps it for Last or lets it go itself.
  useEffect(() => {
    const onHide = () => report(true);
    window.addEventListener("pagehide", onHide);
    return () => {
      window.removeEventListener("pagehide", onHide);
      report();
    };
  }, [report]);

  /** Seek within the airing, never past live. */
  const seekTo = useCallback(
    (seconds: number, { now = false }: { now?: boolean } = {}) => {
      const ceiling = span ? base + liveOffset(span, Date.now() + skew) : video.duration || seconds;
      const target = Math.min(Math.max(seconds, base), ceiling);
      seek(target, { now });
      playhead.set(target);
      reveal();
    },
    [video, span, skew, reveal, base, seek, playhead],
  );
  const jumpToLive = useCallback(() => {
    if (span) seekTo(base + liveOffset(span, Date.now() + skew), { now: true });
    void video.play().catch(() => undefined);
  }, [video, span, skew, seekTo, base]);
  const restart = useCallback(() => {
    if (base > 0) onRestart();
    else seekTo(0, { now: true });
  }, [base, onRestart, seekTo]);

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
          seekTo(position() - 10);
          break;
        case "l":
        case "ArrowRight":
          seekTo(position() + 10);
          break;
        case "Home":
          restart();
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
        case "c":
          setSubtitleId((currentId) => (currentId ? null : (pickable[0]?.id ?? null)));
          break;
        case "i":
          reveal();
          break;
        default:
          return;
      }
      event.preventDefault();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [keys, togglePlay, seekTo, position, restart, jumpToLive, toggleFullscreen, reveal, pickable, toggleMute]);

  const hidden = !controls && playing;

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
      <ChannelBar onBack={onBack} onChannel={onChannel} onGuide={onGuide} onNow={onNow} nowOpen={nowOpen} />

      {failure ? <div className="mx-auto max-w-md rounded-[var(--radius-card)] bg-surface px-5 py-4 text-center text-sm">{failure}</div> : null}

      <div className="space-y-3 bg-gradient-to-t from-background/95 via-background/70 to-transparent px-4 pb-4 pt-16 sm:px-6">
        <div className="flex items-end gap-4" data-testid="channel-banner">
          <div className="shrink-0 text-center">
            <p className="font-mono text-3xl font-semibold tabular-nums leading-none">{live?.number}</p>
            <p className="mt-1 max-w-24 truncate text-xs uppercase tracking-wide text-muted">{live?.name}</p>
          </div>
          <div className="min-w-0 flex-1">
            <p className="truncate text-lg font-semibold">{airing?.title ?? session.title}</p>
            <p className="truncate text-sm text-muted">
              {[airing?.subtitle ?? session.subtitle, airing?.content_rating, live ? `${clockTime(live.starts_at, timeZone, false)} – ${clockTime(live.ends_at, timeZone)}` : null]
                .filter(Boolean)
                .join(" · ")}
            </p>
            {next ? (
              <p className="truncate text-xs text-muted">
                Next at {clockTime(next.starts_at, timeZone)}: {next.title}
                {next.subtitle ? ` · ${next.subtitle}` : ""}
              </p>
            ) : null}
          </div>
          <BehindLive playhead={playhead} liveAt={liveAt} skew={skew} onJump={jumpToLive} />
        </div>

        <ProgramBar
          playhead={playhead}
          liveAt={liveAt}
          skew={skew}
          base={base}
          length={length}
          onSeek={(seconds) => seekTo(seconds, { now: true })}
          onStep={(seconds) => seekTo(position() + seconds)}
        />

        <div className="flex items-center gap-1 sm:gap-2">
          <PlayPauseButton playing={playing} onToggle={togglePlay} />
          <IconButton label="Rewind 10 seconds (j)" size="lg" onClick={() => seekTo(position() - 10)}>
            <RotateCcw className="h-5 w-5" aria-hidden />
          </IconButton>
          <IconButton label="Restart this program (Home)" size="lg" onClick={restart}>
            <SkipBack className="h-5 w-5" aria-hidden />
          </IconButton>
          <VolumeControl quiet={quiet} volume={volume} onToggleMute={toggleMute} onVolume={changeVolume} />
          <span className="ml-2 font-mono text-sm tabular-nums text-muted">
            <AtPlayhead playhead={playhead}>{(current) => formatClock(Math.max(current - base, 0))}</AtPlayhead> / {formatClock(length)}
          </span>
          <span className="flex-1" />
          <SubtitleMenu
            name="live-subtitle-track"
            tracks={pickable}
            offChecked={subtitleId === null}
            checked={(track) => track.id === subtitleId}
            label={subtitleLabel}
            onOff={() => {
              setSubtitleId(null);
              rememberSubtitle(null);
            }}
            onPick={(track) => {
              setSubtitleId(track.id);
              rememberSubtitle(track);
            }}
          />
          {live ? <PipPicker playing={{ kind: "station", stationId: live.station_id, number: live.number, title: live.name }} /> : null}
          <FullscreenButton fullscreen={fullscreen} onToggle={toggleFullscreen} />
        </div>
      </div>
    </div>
  );
}

interface LivePlace {
  playhead: Playhead;
  liveAt: (at: number) => number;
  skew: number;
}

/** Live, or how far behind it. Live moves on by itself, so this ticks; nothing around it does. */
function BehindLive({ playhead, liveAt, skew, onJump }: LivePlace & { onJump: () => void }) {
  const now = useNow(1_000, skew);
  const behind = usePlayheadValue(playhead, (seconds) => Math.floor(Math.max(liveAt(now) - seconds, 0)));
  return <LiveBadge atLive={behind < LIVE_SLACK} behind={behind} onJump={onJump} />;
}

/** The bar: the program, how far live has got through it, and where the viewer is. */
function ProgramBar({
  playhead,
  liveAt,
  skew,
  base,
  length,
  onSeek,
  onStep,
}: LivePlace & { base: number; length: number; onSeek: (seconds: number) => void; onStep: (seconds: number) => void }) {
  const now = useNow(1_000, skew);
  const current = usePlayheadValue(playhead, (seconds) => seconds);
  const progress = length > 0 ? ((current - base) / length) * 100 : 0;
  const livePercent = length > 0 ? ((liveAt(now) - base) / length) * 100 : 0;
  return (
    <ScrubBar
      label="Position in this program"
      max={length}
      now={current - base}
      text={`${formatClock(current - base)} of ${formatClock(length)}`}
      onFraction={(fraction) => onSeek(base + fraction * length)}
      onStep={onStep}
    >
      <div className="absolute inset-y-0 left-0 rounded-full bg-foreground/30" style={{ width: `${livePercent}%` }} />
      <div className="absolute inset-y-0 left-0 rounded-full bg-primary" style={{ width: `${progress}%` }} />
      <div className="absolute -top-1 h-3.5 w-0.5 bg-negative" style={{ left: `${livePercent}%` }} aria-hidden />
    </ScrubBar>
  );
}
