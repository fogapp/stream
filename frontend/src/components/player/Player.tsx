import { useCallback, useEffect, useEffectEvent, useMemo, useRef, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { ArrowLeft, Expand, FoldHorizontal, ListVideo, Minimize2, Square, UnfoldHorizontal, X, RotateCcw, RotateCw, VolumeX } from "lucide-react";
import { FullscreenButton, PlayPauseButton, SubtitleMenu, VolumeControl } from "@/components/player/controls";
import { MiniTransport } from "@/components/player/MiniTransport";
import { AudioMenu, SettingsMenu } from "@/components/player/PlayerMenus";
import { runPlayerKey, stepSpeed } from "@/components/player/playerKeymap";
import { SeekBar } from "@/components/player/SeekBar";
import { usePlayerVolume } from "@/components/player/usePlayerVolume";
import { useSeekBatch } from "@/components/player/useSeekBatch";
import { useSessionEvents, useSessionReporting } from "@/components/player/useSessionReporting";
import { useStallWatch } from "@/components/player/useStallWatch";
import { useAutoHide } from "@/components/player/useAutoHide";
import { AtPlayhead, AtProgress, usePlayhead, usePlayheadValue } from "@/components/player/playhead";
import { attachSource } from "@/components/player/source";
import { failureMessage, mediaErrorFailure, type PlayFailure } from "@/components/player/failure";
import { needsAudioGraph, playOrMute, useAudioLevelling, volumeScale } from "@/components/player/audio";
import { KeySheet } from "@/components/player/KeySheet";
import { RelatedPanel } from "@/components/player/RelatedPanel";
import { hasRelated } from "@/components/player/related";
import { useMiniFrame, type InsetArea } from "@/components/player/miniFrame";
import { FrameCorners, MINI_BUTTON } from "@/components/player/FrameCorners";
import { PipControls } from "@/components/pip/PipControls";
import { PipPicker } from "@/components/pip/PipPicker";
import { useAnchorBox } from "@/components/player/anchor";
import { SkipButton } from "@/components/player/SkipButton";
import { SponsorSkip } from "@/components/player/SponsorSkip";
import { StatsOverlay } from "@/components/player/StatsOverlay";
import { recoveryLog } from "@/components/player/recoveries";
import { usePlaybackTiming, type StartMark } from "@/components/player/timing";
import { hasMediaSource, prefersNativeHls } from "@/lib/capabilities";
import { UpNext } from "@/components/player/UpNext";
import { EndScreen } from "@/components/player/EndScreen";
import { rememberAutoplay, storedAutoplay, useEndScreen } from "@/components/player/offers";
import { fromTv, tvPath } from "@/lib/tv";
import { api } from "@/api/client";
import { initialSubtitle, rememberSubtitle, subtitleLabel, useSubtitles } from "@/components/player/subtitles";
import { Button } from "@/components/ui/Button";
import { IconButton } from "@/components/ui/IconButton";
import { cn } from "@/lib/cn";
import { formatClock } from "@/lib/format";
import { keys } from "@/lib/queryKeys";
import { useLatest } from "@/hooks/useLatest";
import { useProfile } from "@/hooks/useProfile";
import { useDocumentFullscreen } from "@/hooks/useDocumentFullscreen";
import { notAShortcut } from "@/lib/keys";
import { rememberMuted, storedVolume } from "@/lib/volume";
import { fullWidthSize, storedFillWindow, storeFillWindow, type PlayerSize } from "@/lib/playerSize";
import { swapOnDoubleClick, toggleFullscreen as fullscreenToggle, type PipAudio } from "@/lib/pip";
import type { MarkerKind, NextItem, PlayableKind, PlaybackSessionInfo } from "@/types";

const BINGE_KEY = "stream_binge";

const AUDIO_KEY = "stream_audio";

function storedAudio(): { levelling: boolean; night: boolean } {
  try {
    const parsed = JSON.parse(localStorage.getItem(AUDIO_KEY) ?? "{}") as { levelling?: boolean; night?: boolean };
    return { levelling: parsed.levelling ?? true, night: parsed.night ?? false };
  } catch {
    return { levelling: true, night: false };
  }
}

function bingeCount(): number {
  try {
    return Number(sessionStorage.getItem(BINGE_KEY) ?? 0) || 0;
  } catch {
    return 0;
  }
}

function setBingeCount(value: number) {
  try {
    sessionStorage.setItem(BINGE_KEY, String(value));
  } catch {
    // A nicety.
  }
}

/** The Related panel stays open from one item to the next chosen from it. */
let relatedOpen = false;

/** Keys meant for a control on the page, not for a player playing in it. */
const PAGE_CONTROLS = "a, button, input, select, textarea, [contenteditable], [role=menuitem], [role=radio], [role=tab]";

/**
 * The player (PROPOSAL §7.3): the original file, or an HLS stream from the
 * transcoder — Safari's own HLS there, hls.js everywhere else — behind our
 * own controls, keyboard-complete, resuming where the profile left off and
 * reporting where it is so the next device can too. Changing the audio
 * track asks for a new session at the current position. Phase 3 adds skip,
 * up next and the mini-player.
 */
export function Player({
  item,
  session,
  startAt,
  mark = null,
  onChooseAudio,
  onChooseBurn,
  onPrefetch,
  onNext,
  mode = "full",
  anchor = null,
  size = "normal",
  onSize,
  seekRequest = null,
  onBack,
  onExpand,
  onClose,
  onReport,
  onFallback,
  onUpgrade,
  onFailed,
  silenced = false,
  onUnsilence,
  insetUp = false,
  inset,
  onVideo,
}: {
  /** What's playing, for the Related panel (an extra has none). */
  item: { kind: PlayableKind; id: string };
  session: PlaybackSessionInfo;
  startAt: number;
  /** When Play was pressed and the session answered: where startup timing counts from. */
  mark?: StartMark | null;
  onChooseAudio: (audioIndex: number, position: number) => void;
  /** Restart with a picture subtitle burned in, or without one (null). */
  onChooseBurn: (streamIndex: number | null, position: number) => void;
  onPrefetch: (next: NextItem) => void;
  onNext: (next: NextItem) => void;
  /** The whole window on /watch; laid over a page's slot (a video on its page); the corner; or the inset over another picture. */
  mode?: "full" | "inline" | "mini" | "pip";
  /** Inline: the page's slot to lie over. */
  anchor?: HTMLElement | null;
  size?: PlayerSize;
  onSize?: (size: PlayerSize) => void;
  /** Inline: jump here when asked (a timestamp on the page). */
  seekRequest?: { at: number; nonce: number } | null;
  /** Full, expanded from the corner over a page: Back shrinks it again instead of leaving. */
  onBack?: () => void;
  onExpand?: () => void;
  onClose?: () => void;
  /** Each progress report, with the frame on screen: the provider remembers it for after a reload. */
  onReport?: (position: number, duration: number, still: string | null) => void;
  /**
   * This play can't go on as it is: carry it on a rung down the ladder from
   * here. Rejects with why when there's
   * no rung left.
   */
  onFallback?: (failure: PlayFailure, position: number) => Promise<void>;
  /**
   * This play has stopped for good — no rung left, or a browser that can't
   * stream at all — and why, in the viewer's words: the owner says so and
   * takes the player off the screen.
   */
  onFailed: (message: string) => void;
  /** A play that fell back for a passing reason, at a seek: climb back if there's a better rung (R2). */
  onUpgrade?: (position: number) => Promise<void>;
  /** Quiet because the other picture's sound was chosen (picture in picture), whatever its own volume. */
  silenced?: boolean;
  /** Unmuted while silenced: the viewer wants this one heard too. */
  onUnsilence?: () => void;
  /** Another picture is over or under this one: browser full screen takes the whole page, so both show. */
  insetUp?: boolean;
  /** In the inset: whose sound plays, Swap, and the main picture it's kept inside (none: the window). */
  inset?: { audio: PipAudio; onAudio: (audio: PipAudio) => void; onSwap: () => void; area: InsetArea | null };
  /** The picture itself, for the inset to be kept inside. */
  onVideo?: (element: HTMLVideoElement | null) => void;
}) {
  const full = mode === "full";
  const inline = mode === "inline";
  const asInset = mode === "pip";
  // The full controls: everywhere but the corner and the inset.
  const chrome = mode !== "mini" && !asInset;
  const windowed = inline && size === "window";
  const corner = useMiniFrame("mini");
  const insetFrame = useMiniFrame("pip", inset?.area?.box ?? null);
  const mini = asInset ? insetFrame : corner;
  const anchorBox = useAnchorBox(inline ? anchor : null);
  // Played from the TV layout: Back goes to the TV's pages.
  const backPath = fromTv() ? tvPath(session.back_path) : session.back_path;
  const navigate = useNavigate();
  const goBack = useCallback(() => (onBack ? onBack() : navigate(backPath)), [onBack, navigate, backPath]);
  const video = useRef<HTMLVideoElement>(null);
  const frame = useRef<HTMLDivElement>(null);
  const [playing, setPlaying] = useState(false);
  const playhead = usePlayhead(startAt);
  // Where the source was last attached from (onLoadedMetadata seeks a file there).
  const attachFrom = useRef(startAt);
  // Where the viewer was when the source was last detached, and the start it
  // was attached from: detaching resets the element to 0, so it's kept here.
  const detachedAt = useRef<{ startAt: number; at: number } | null>(null);
  const [duration, setDuration] = useState(session.duration_seconds ?? 0);
  // How far it has loaded: a store like the playhead, so a progress event
  // re-renders only the seek bar.
  const buffered = usePlayhead(0);
  // A profile that autoplays videos (Settings › Viewing): if the browser
  // won't start one with sound, it starts muted and says so.
  const { profile } = useProfile();
  const autoplayMuted = item.kind === "video" && (profile?.autoplay_videos ?? false);
  const autoplayTried = useRef(false);
  const [mutedForAutoplay, setMutedForAutoplay] = useState(false);
  const fullscreen = useDocumentFullscreen();
  const { shown: controls, reveal, show: showControls } = useAutoHide(() => video.current?.paused ?? false);
  const [showStats, setShowStats] = useState(false);
  // Which version of an adaptive stream is playing (stats for nerds).
  const [quality, setQuality] = useState<string | null>(null);
  const [showKeys, setShowKeys] = useState(false);
  const related = hasRelated(item, session);
  const [showRelated, setShowRelatedState] = useState(() => relatedOpen && related);
  const setShowRelated = useCallback((open: boolean) => {
    relatedOpen = open;
    setShowRelatedState(open);
  }, []);
  const [rate, setRate] = useState(1);
  const [audioPrefs, setAudioPrefs] = useState(storedAudio);
  const lastSubtitle = useRef<string | null>(null);
  const [autoSkip, setAutoSkip] = useState(session.skip);
  const [upNextDismissed, setUpNextDismissed] = useState(false);
  // A finished video with nothing next: what to watch instead, over its last frame.
  const endScreen = useEndScreen(item);
  const [over, setOver] = useState(false);
  const [autoplayOffers, setAutoplayOffers] = useState(storedAutoplay);
  const prefetched = useRef(false);
  const next = session.next_up;
  const creditsAt = session.markers.find((marker) => marker.kind === "credits")?.start ?? (duration > 120 ? duration - 20 : Infinity);
  const inCredits = usePlayheadValue(playhead, (seconds) => seconds >= creditsAt);
  // Credits are left to Up next when there's something next.
  const skippable = useMemo(() => session.markers.filter((marker) => !(next && marker.kind === "credits")), [session.markers, next]);
  const showUpNext = next !== null && !upNextDismissed && duration > 0 && inCredits;
  // Episodes in a row with nobody touching anything before Up next asks
  // (the profile's number; 0 never asks).
  const stillWatching = session.still_watching_after > 0 && bingeCount() >= session.still_watching_after;

  // Someone touched the player: the binge counter starts over.
  useEffect(() => {
    const reset = () => setBingeCount(0);
    window.addEventListener("keydown", reset);
    window.addEventListener("pointerdown", reset);
    return () => {
      window.removeEventListener("keydown", reset);
      window.removeEventListener("pointerdown", reset);
    };
  }, []);

  // Warm the next episode as soon as Up next shows.
  useEffect(() => {
    if (showUpNext && next && !prefetched.current) {
      prefetched.current = true;
      onPrefetch(next);
    }
  }, [showUpNext, next, onPrefetch]);

  // "Always skip" is the show's preference from now on: saved, and its page's
  // copy refreshed. A failure gets the shared toast; this session skips anyway.
  const queryClient = useQueryClient();
  const { mutate: saveSkip } = useMutation({
    mutationFn: ({ showId, kind }: { showId: string; kind: MarkerKind }) => api.patch(`/shows/${showId}/preferences`, { [`skip_${kind}`]: true }),
    onSuccess: (_data, { showId }) => void queryClient.invalidateQueries({ queryKey: keys.shows.detail(showId) }),
  });
  const alwaysSkip = useCallback(
    (kind: MarkerKind) => {
      setAutoSkip((current) => ({ ...current, [kind]: true }));
      if (session.show_id) saveSkip({ showId: session.show_id, kind });
    },
    [session.show_id, saveSkip],
  );
  const [videoElement, setVideoElement] = useState<HTMLVideoElement | null>(null);
  const [subtitleId, setSubtitleId] = useState<string | null>(() => initialSubtitle(session.subtitles));
  const subtitle = session.subtitles.find((track) => track.id === subtitleId) ?? null;
  useSubtitles(videoElement, subtitle, session.fonts);
  // Safari's own HLS is the better player there (AirPlay, picture in
  // picture, HDR, formats its MediaSource lacks) but can't feed Web Audio.
  // So a stream goes through hls.js on Safari only when someone turns night
  // mode on; levelling there can still only turn a loud file down.
  const safariHls = session.source.kind === "hls" && prefersNativeHls();
  const nativeHls = safariHls && !(audioPrefs.night && hasMediaSource());
  const webAudio = session.source.kind === "file" || !nativeHls;
  // The sound as it reaches the element: the file's own rate when it's copied.
  const plannedAudio = session.decision.audio;
  const sampleRate = plannedAudio?.copy ? (session.media_file?.audio.find((track) => track.index === plannedAudio.index)?.sample_rate ?? null) : null;
  // Each time a routed element's sound is lined up with its picture again:
  // counted for the stats overlay, and sent as a recovery (set by the source).
  const [resyncs, setResyncs] = useState(0);
  const onResync = useRef<(() => void) | null>(null);
  const levelling = useAudioLevelling(videoElement, session.loudness, { ...audioPrefs, webAudio, sampleRate }, () => onResync.current?.());
  const audioGraph = levelling.routed;
  const routeAudio = levelling.route;
  const scale = volumeScale(session.loudness, audioPrefs.levelling, audioGraph);
  // The sound goes through the levelling graph only when this file needs
  // it (night mode, or turning it up: needsAudioGraph) — Web Audio costs
  // the picture its sync — and then from the moment the element exists,
  // before it has any data (docs/PERF_PROPOSAL.md › P22): the press that
  // started playing already started the shared AudioContext, so nothing is
  // moved once it's audible. Night mode turned on mid-film routes it then
  // (and in Safari moves a stream onto hls.js).
  const wantsGraph = webAudio && needsAudioGraph(session.loudness, audioPrefs);
  useEffect(() => {
    if (wantsGraph) routeAudio();
  }, [wantsGraph, routeAudio]);

  useEffect(() => {
    if (videoElement) videoElement.playbackRate = rate;
  }, [videoElement, rate]);

  // Silenced by the other picture's sound, it's muted whatever its own volume says.
  // The element's own volume is the chosen one times the levelling scale.
  const { volume, muted, setMuted, quiet, changeVolume, toggleMute } = usePlayerVolume({ element: videoElement, scale, silenced, onUnsilence });

  // Leaving for the corner leaves browser full screen too (the inset stays
  // over the main picture, full screen or not).
  const inCorner = mode === "mini";
  useEffect(() => {
    if (inCorner && document.fullscreenElement) void document.exitFullscreen().catch(() => undefined);
  }, [inCorner]);

  const changeAudio = useCallback((change: Partial<{ levelling: boolean; night: boolean }>) => {
    setAudioPrefs((currentPrefs) => {
      const nextPrefs = { ...currentPrefs, ...change };
      try {
        localStorage.setItem(AUDIO_KEY, JSON.stringify(nextPrefs));
      } catch {
        // A nicety.
      }
      return nextPrefs;
    });
  }, []);
  const { note, flushEvents } = useSessionEvents(session.events_url);
  const lastTime = useRef(startAt);

  // A play that can't go on carries on a rung down, once per session:
  // the server records why. Only when
  // there's no rung left does the viewer see why it stopped.
  const fellBack = useRef(false);
  // Read when they're needed: the provider passes new ones every render, and
  // the source must not be attached again for that. (Not Effect Events: a
  // media event and a seek call these, not an Effect.)
  const onFallbackRef = useLatest(onFallback);
  const onUpgradeRef = useLatest(onUpgrade);
  const onFailedRef = useLatest(onFailed);
  const fallBack = useCallback(
    (failure: PlayFailure) => {
      if (fellBack.current) return;
      fellBack.current = true;
      const element = video.current;
      const position = element && element.readyState > 0 ? element.currentTime : attachFrom.current;
      note({ kind: "error", position, detail: { message: failure.cause, failure: failure.failureClass } });
      flushEvents();
      const carryOn = onFallbackRef.current;
      if (!carryOn) {
        onFailedRef.current(failureMessage(failure));
        return;
      }
      carryOn(failure, position).catch((reason: unknown) => {
        onFailedRef.current(reason instanceof Error ? reason.message : failureMessage(failure));
      });
    },
    [note, flushEvents, onFallbackRef, onFailedRef],
  );
  const stall = useStallWatch(note, fallBack);
  // A carried-on play says so for a moment, then gets out of the way.
  const [switched, setSwitched] = useState(session.fallback !== null);
  useEffect(() => {
    if (!switched) return;
    const timer = window.setTimeout(() => setSwitched(false), 3_000);
    return () => window.clearTimeout(timer);
  }, [switched]);
  // Climbing back (R2, "Upgrading back"): after two minutes played on a rung
  // it fell to for a passing reason, the next seek asks for the better one.
  const played = useRef(0);
  const upgradeTried = useRef(false);

  // How long it took to start, and each seek to land: sent as they happen.
  const timing = usePlaybackTiming(videoElement, mark, (kind, position, detail) => {
    note({ kind, position, detail: { ...detail } });
    flushEvents();
  });
  const milestone = timing.milestone;

  // Attach the source: a file, or HLS natively (Safari) or through hls.js.
  // Switching between the two mid-film (night mode turned on in Safari)
  // attaches again from where the viewer is — read before detaching, since
  // detaching puts the element back to 0. A new start (another session)
  // starts there instead. StrictMode's rehearsal detaches before anything
  // loaded, so it keeps the start it was given.
  useEffect(() => {
    const element = video.current;
    if (!element) return;
    const previous = detachedAt.current;
    const from = previous && previous.startAt === startAt ? previous.at : startAt;
    attachFrom.current = from;
    // What playback got past by itself, counted and sent a few seconds apart.
    const recovered = recoveryLog((recoveries) => {
      for (const { position, ...detail } of recoveries) note({ kind: "recovery", position, detail });
      flushEvents();
    });
    const attached = attachSource(element, session.source, from, nativeHls, {
      onQuality: setQuality,
      onMilestone: milestone,
      onRecovery: (what, cause) => recovered.add(what, element.currentTime, cause),
      onUnsupported: () => onFailedRef.current("This browser can't play streamed video."),
      onFailure: fallBack,
    }, { fallback: true });
    onResync.current = () => {
      recovered.add("audio resynced", element.currentTime);
      setResyncs((count) => count + 1);
    };
    // A start that never comes is a failure too: thirty seconds of nothing.
    const startTimer = window.setTimeout(() => {
      if (element.readyState < 2 && !element.error) fallBack({ failureClass: "stalled", cause: "nothing to show after 30 s" });
    }, 30_000);
    return () => {
      window.clearTimeout(startTimer);
      detachedAt.current = { startAt, at: element.readyState > 0 ? element.currentTime : from };
      onResync.current = null;
      recovered.flush();
      attached.detach();
    };
  }, [session.source, startAt, note, flushEvents, nativeHls, milestone, fallBack, onFailedRef]);

  // While playing, every ten seconds; and a final report however we leave.
  const report = useSessionReporting({ video, url: session.progress_url, playing, flushEvents, onReport });

  const advance = useCallback(
    (automatic: boolean) => {
      if (!next) return;
      setBingeCount(automatic ? bingeCount() + 1 : 0);
      report(true);
      onNext(next);
    },
    [next, onNext, report],
  );

  const togglePlay = useCallback(() => {
    const element = video.current;
    if (!element) return;
    if (element.paused) void element.play().catch(() => undefined);
    else element.pause();
    reveal();
  }, [reveal]);

  const { position, seeking, seek } = useSeekBatch(useCallback(() => video.current, []));
  const seekTo = useCallback(
    (seconds: number, { now = false }: { now?: boolean } = {}) => {
      const element = video.current;
      if (!element) return;
      const target = Math.min(Math.max(seconds, 0), element.duration || seconds);
      const climb = onUpgradeRef.current;
      if (session.fallback?.upgradable && climb && !upgradeTried.current && played.current >= 120) {
        upgradeTried.current = true;
        void climb(target).catch(() => undefined);
      }
      seek(target, { now });
      playhead.set(target);
      reveal();
    },
    [reveal, session.fallback, playhead, seek, onUpgradeRef],
  );

  // With an inset up, full screen is the whole page so it shows too; a
  // player in a page's slot is still its own frame.
  const pageFullscreen = insetUp && (full || windowed);
  const toggleFullscreen = useCallback(() => fullscreenToggle(pageFullscreen ? document.documentElement : frame.current), [pageFullscreen]);

  // Off the screen for good: from /watch, back to where it came from, with
  // nothing left playing in the corner.
  const leave = useCallback(() => {
    if (full && !onBack) navigate(backPath);
    onClose?.();
  }, [full, onBack, navigate, backPath, onClose]);

  // Stop: done watching for now. Where it got to is kept, and nothing is
  // left playing in the corner; from /watch, back to where it came from.
  const stop = useCallback(() => {
    report();
    leave();
  }, [report, leave]);

  // Normal, or Full Width: across the page, or over the window for someone
  // who has set Full Width to use it.
  const [fillWindow, setFillWindow] = useState(storedFillWindow);
  const toggleSize = useCallback(() => {
    onSize?.(size === "normal" ? fullWidthSize(fillWindow) : "normal");
  }, [onSize, size, fillWindow]);
  const changeFillWindow = useCallback(
    (fill: boolean) => {
      setFillWindow(fill);
      storeFillWindow(fill);
      if (size !== "normal") onSize?.(fullWidthSize(fill));
    },
    [onSize, size],
  );

  // A timestamp on the page: jump there without starting over.
  // Only for a new request, with the player as it is then.
  const jumpTo = useEffectEvent((at: number) => {
    seekTo(at, { now: true });
    void video.current?.play().catch(() => undefined);
  });
  useEffect(() => {
    if (seekRequest) jumpTo(seekRequest.at);
  }, [seekRequest]);

  // A key, read with the player as it is now: the listener below is added
  // once per player with controls, not again on every render.
  const onKey = useEffectEvent((event: KeyboardEvent) => {
    if (notAShortcut(event)) return;
    if (
      inline &&
      event.target instanceof Element &&
      !frame.current?.contains(event.target) &&
      event.target.closest(PAGE_CONTROLS)
    )
      return;
    const element = video.current;
    if (!element) return;
    const taken = runPlayerKey(event.key, {
      element,
      position,
      seekTo,
      togglePlay,
      volume,
      changeVolume,
      mute: () => {
        if (silenced) {
          onUnsilence?.();
          if (muted) changeVolume(volume || storedVolume());
          return;
        }
        element.muted = !element.muted;
        setMuted(element.muted);
        rememberMuted(element.muted);
      },
      changeRate: (step) => setRate((value) => stepSpeed(value, step)),
      frameRate: session.frame_rate,
      toggleSubtitles: () =>
        setSubtitleId((currentId) => {
          if (currentId) {
            lastSubtitle.current = currentId;
            return null;
          }
          return lastSubtitle.current ?? session.subtitles[0]?.id ?? null;
        }),
      info: full ? goBack : null,
      toggleSize: inline ? toggleSize : null,
      next: next ? () => advance(false) : null,
      toggleKeys: () => setShowKeys((value) => !value),
      toggleFullscreen,
      toggleStats: () => setShowStats((value) => !value),
      toggleRelated: () => {
        if (full && related) setShowRelated(!showRelated);
      },
      escape: () => {
        if (showKeys) setShowKeys(false);
        else if (full && showRelated) setShowRelated(false);
        else if (document.fullscreenElement) return false;
        else if (windowed) onSize?.("normal");
        else if (full) goBack();
        else return false;
        return true;
      },
    });
    if (taken) event.preventDefault();
  });
  useEffect(() => {
    // Shortcuts belong to a player with its controls; a mini-player in the
    // corner mustn't take the keys of the page underneath it, nor one in a
    // page those of the page's own buttons and fields.
    if (!chrome) return;
    const listener = (event: KeyboardEvent) => onKey(event);
    document.addEventListener("keydown", listener);
    return () => document.removeEventListener("keydown", listener);
  }, [chrome]);

  // Said once per element (the ref above runs every render), and taken back when it goes.
  useEffect(() => {
    if (!onVideo || !videoElement) return;
    onVideo(videoElement);
    return () => onVideo(null);
  }, [onVideo, videoElement]);

  const hidden = !controls && playing;

  return (
    <div
      ref={frame}
      data-theme="dark"
      className={cn(
        "bg-background text-foreground",
        full || windowed
          ? cn("fixed inset-0 z-50", hidden && "cursor-none")
          : inline
            ? // Under the shell's header and drawer as the page scrolls.
              cn("absolute z-10 overflow-hidden rounded-[var(--radius-card)] ring-1 ring-border", hidden && "cursor-none", !anchorBox && "invisible")
            : cn(
                // The inset sits over a full-window picture; the corner over a page.
                "group touch-none select-none overflow-hidden rounded-[var(--radius-card)] shadow-xl ring-1 ring-border",
                // The inset is moved by any part of it; the corner's picture expands on a click.
                // Over a picture in a page, it scrolls with the page under the header.
                asInset ? cn("cursor-grab", inset?.area?.page ? "absolute z-[15]" : "fixed z-[60]") : "fixed z-50",
                mini.dragging && "cursor-grabbing",
              ),
      )}
      style={
        full || windowed
          ? undefined
          : inline
            ? (anchorBox ?? undefined)
            : { left: mini.box.left, top: mini.box.top, width: mini.box.width, height: mini.box.height }
      }
      {...(chrome ? {} : { ...mini.frameProps, tabIndex: 0, onKeyDown: mini.onKeyDown })}
      aria-label={full ? undefined : asInset ? `Picture in picture: ${session.title}` : `Now playing: ${session.title}`}
      role={full ? undefined : "region"}
      data-testid={asInset ? "pip" : undefined}
      onDoubleClick={asInset ? (event) => swapOnDoubleClick(event, inset?.onSwap) : undefined}
      onMouseMove={reveal}
      onTouchStart={reveal}
    >
      <video
        ref={(element) => {
          video.current = element;
          setVideoElement(element);
        }}
        // Beside the Related panel rather than under it, where there's room.
        className={cn("h-full w-full", full && showRelated && "sm:w-[calc(100%-20rem)]")}
        preload="auto"
        autoPlay
        playsInline
        draggable={false}
        onClick={chrome ? togglePlay : asInset ? undefined : onExpand}
        onDoubleClick={chrome ? toggleFullscreen : undefined}
        onLoadedMetadata={(event) => {
          const element = event.currentTarget;
          element.volume = Math.min(1, (muted ? 0 : volume) * scale);
          // hls.js starts where it was told (startPosition); a file and
          // Safari's own HLS are moved there here.
          const from = attachFrom.current;
          const placed = session.source.kind === "hls" && !nativeHls;
          if (!placed && from > 0 && from < element.duration - 5) element.currentTime = from;
          setDuration(element.duration);
        }}
        onCanPlay={(event) => {
          const element = event.currentTarget;
          if (!autoplayMuted || autoplayTried.current || !element.paused) return;
          autoplayTried.current = true;
          playOrMute(element, () => {
            setMuted(true);
            setMutedForAutoplay(true);
          });
        }}
        onTimeUpdate={(event) => {
          // The bar shows a seek that hasn't landed yet where it's going.
          if (!seeking()) playhead.set(event.currentTarget.currentTime);
          const now = event.currentTarget.currentTime;
          const step = now - lastTime.current;
          lastTime.current = now;
          if (!event.currentTarget.paused && step > 0 && step < 1.5) played.current += step;
        }}
        onWaiting={(event) => stall.onWaiting(event.currentTarget)}
        onPlaying={(event) => stall.onPlaying(event.currentTarget)}
        onProgress={(event) => {
          const ranges = event.currentTarget.buffered;
          buffered.set(ranges.length > 0 ? ranges.end(ranges.length - 1) : 0);
        }}
        onPlay={() => {
          setPlaying(true);
          setOver(false);
          reveal();
        }}
        onPause={() => {
          setPlaying(false);
          showControls();
          report();
        }}
        onEnded={() => {
          if (next && !stillWatching) {
            advance(true);
            return;
          }
          // Still watching? stays on screen for an answer.
          if (next) return;
          report(true);
          if (chrome && endScreen) {
            setOver(true);
            return;
          }
          // Finished with nothing next: back to where it came from, and no
          // spent mini-player left behind.
          leave();
        }}
        onError={(event) => {
          if (session.source.kind === "hls" && !event.currentTarget.src) return; // hls.js reports its own
          const failure = mediaErrorFailure(event.currentTarget.error);
          if (failure) fallBack(failure);
        }}
      />

      {mutedForAutoplay && muted && !silenced ? (
        <Button
          variant="secondary"
          size="sm"
          className={cn(
            "absolute z-20 shadow-lg",
            !chrome ? "left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2" : full || windowed || fullscreen ? "left-4 top-20 sm:left-6" : "left-3 top-3",
          )}
          onClick={() => {
            setMutedForAutoplay(false);
            changeVolume(volume || storedVolume());
          }}
        >
          <VolumeX className="h-4 w-4" aria-hidden />
          Unmute
        </Button>
      ) : null}
      {asInset && inset ? (
        <AtProgress playhead={playhead} duration={duration}>
          {(progress) => (
            <PipControls
              title={session.title}
              subtitle={session.subtitle}
              audio={inset.audio}
              heard={!silenced}
              onAudio={inset.onAudio}
              onSwap={inset.onSwap}
              onClose={() => {
                report();
                onClose?.();
              }}
              progress={progress}
            >
              <MiniTransport playing={playing} onToggle={togglePlay} onStep={(seconds) => seekTo(playhead.get() + seconds)} />
            </PipControls>
          )}
        </AtProgress>
      ) : chrome ? null : (
        <div className="pointer-events-none absolute inset-0 flex flex-col justify-between bg-gradient-to-b from-background/90 via-background/20 to-background/90 opacity-0 transition-opacity focus-within:opacity-100 group-hover:opacity-100">
          <div className="pointer-events-auto flex items-center gap-1 p-2">
            <Link
              to={backPath}
              draggable={false}
              title={session.subtitle ? `${session.title} · ${session.subtitle}` : session.title}
              className="min-w-0 flex-1 truncate px-1 text-sm font-semibold text-foreground drop-shadow hover:underline"
            >
              {session.title}
            </Link>
            <IconButton label="Expand" className={MINI_BUTTON} onClick={onExpand}>
              <Expand className="h-4 w-4" aria-hidden />
            </IconButton>
            <IconButton label="Close player" className={MINI_BUTTON} onClick={() => {
              report();
              onClose?.();
            }}>
              <X className="h-4 w-4" aria-hidden />
            </IconButton>
          </div>
          <div className="pointer-events-auto flex items-center justify-center gap-3 pb-2">
            <MiniTransport playing={playing} onToggle={togglePlay} onStep={(seconds) => seekTo(playhead.get() + seconds)} />
          </div>
          <div className="h-0.5 bg-foreground/20">
            <AtProgress playhead={playhead} duration={duration}>
              {(progress) => <div className="h-full bg-primary" style={{ width: `${progress * 100}%` }} />}
            </AtProgress>
          </div>
        </div>
      )}
      {chrome ? null : <FrameCorners cornerProps={mini.cornerProps} />}

      {chrome ? (
      <div
        className={cn(
          "pointer-events-none absolute inset-0 flex flex-col justify-between transition-opacity duration-300",
          full && showRelated && "sm:right-80",
          hidden ? "opacity-0" : "opacity-100",
        )}
      >
        {/* First, so the title bar after it (positioned too) stays on top and usable. */}
        {over && endScreen ? (
          <EndScreen
            offers={endScreen}
            belowBar={full || windowed || fullscreen}
            autoplay={autoplayOffers}
            seconds={session.up_next_seconds}
            stillWatching={stillWatching}
            onAutoplay={(on) => {
              setAutoplayOffers(on);
              rememberAutoplay(on);
            }}
            onPrefetch={onPrefetch}
            onPlay={(chosen, automatic) => {
              setBingeCount(automatic ? bingeCount() + 1 : 0);
              onNext(chosen);
            }}
            onReplay={() => {
              seekTo(0, { now: true });
              void video.current?.play().catch(() => undefined);
            }}
            onClose={() => {
              setOver(false);
              leave();
            }}
          />
        ) : null}
        {/* In a page the title is the page's; over the window it's the player's. */}
        {full || windowed || fullscreen ? (
        <div className="pointer-events-auto relative flex items-center gap-3 bg-gradient-to-b from-background/80 to-transparent px-4 pb-10 pt-4 sm:px-6">
          {full ? (
            <IconButton label="Back" size="lg" onClick={goBack}>
              <ArrowLeft className="h-5 w-5" aria-hidden />
            </IconButton>
          ) : windowed && !fullscreen ? (
            <IconButton label="Exit full window (Esc)" size="lg" onClick={() => onSize?.("normal")}>
              <Minimize2 className="h-5 w-5" aria-hidden />
            </IconButton>
          ) : null}
          <div className="min-w-0 flex-1">
            {/* The title goes to its own page (an episode's show); the player
                follows to the corner, or shrinks back over the page it came from. */}
            <Link to={backPath} onClick={onBack} className="block truncate font-semibold hover:underline">
              {session.title}
            </Link>
            {session.subtitle ? <p className="truncate text-sm text-muted">{session.subtitle}</p> : null}
          </div>
          {full && related ? (
            <IconButton label="Related" size="lg" aria-pressed={showRelated} onClick={() => setShowRelated(!showRelated)}>
              <ListVideo className="h-5 w-5" aria-hidden />
            </IconButton>
          ) : null}
        </div>
        ) : (
          <span />
        )}

        {showStats ? <StatsOverlay video={videoElement} session={session} quality={quality} startup={timing.startup} lastSeek={timing.lastSeek} sound={{ levelling: audioPrefs.levelling, night: audioPrefs.night, sampleRate, resyncs }} /> : null}
        {over && endScreen ? null : (
          <AtPlayhead playhead={playhead}>
            {(current) => <SponsorSkip segments={session.segments} current={current} onSeek={(seconds) => seekTo(seconds, { now: true })} />}
          </AtPlayhead>
        )}
        <AtPlayhead playhead={playhead}>
          {(current) => (
            <SkipButton
              markers={skippable}
              current={current}
              autoSkip={autoSkip}
              canAlwaysSkip={Boolean(session.show_id)}
              onSkip={seekTo}
              onAlwaysSkip={(kind) => {
                alwaysSkip(kind);
                const marker = session.markers.find((candidate) => candidate.kind === kind);
                if (marker) seekTo(marker.end, { now: true });
              }}
            />
          )}
        </AtPlayhead>
        {showUpNext && next ? (
          <UpNext
            next={next}
            seconds={session.up_next_seconds}
            stillWatching={stillWatching}
            onPlay={() => advance(!stillWatching)}
            onDismiss={() => {
              setUpNextDismissed(true);
              if (stillWatching) goBack();
            }}
          />
        ) : null}
        {switched ? (
          <div role="status" className="mx-auto rounded-[var(--radius-card)] bg-surface/90 px-4 py-2 text-center text-sm text-muted">
            Switched to a steadier stream
          </div>
        ) : null}

        {/* The end screen's Replay and Close stand in for the controls. */}
        <div className={cn("pointer-events-auto space-y-2 bg-gradient-to-t from-background/90 to-transparent px-4 pb-4 pt-12 sm:px-6", over && endScreen && "invisible")}>
          <AtPlayhead playhead={playhead}>
            {(current) => (
              <AtPlayhead playhead={buffered}>
                {(loaded) => (
                  <SeekBar current={current} duration={duration} buffered={loaded} chapters={session.chapters} segments={session.segments} trickplay={session.trickplay} onSeek={(seconds) => seekTo(seconds, { now: true })} />
                )}
              </AtPlayhead>
            )}
          </AtPlayhead>
          <div className="flex items-center gap-1 sm:gap-2">
            <PlayPauseButton playing={playing} onToggle={togglePlay} />
            <IconButton label="Stop" size="lg" onClick={stop}>
              <Square className="h-5 w-5 fill-current" aria-hidden />
            </IconButton>
            <IconButton label="Rewind 10 seconds (j)" size="lg" onClick={() => seekTo(playhead.get() - 10)}>
              <RotateCcw className="h-5 w-5" aria-hidden />
            </IconButton>
            <IconButton label="Skip forward 10 seconds (l)" size="lg" onClick={() => seekTo(playhead.get() + 10)}>
              <RotateCw className="h-5 w-5" aria-hidden />
            </IconButton>
            <VolumeControl quiet={quiet} volume={volume} onToggleMute={toggleMute} onVolume={changeVolume} />
            <span className="ml-2 font-mono text-sm tabular-nums text-muted">
              <AtPlayhead playhead={playhead}>{(current) => formatClock(current)}</AtPlayhead> / {formatClock(duration)}
            </span>
            <span className="flex-1" />
            <SubtitleMenu
              name="subtitle-track"
              tracks={session.subtitles}
              offChecked={subtitleId === null && !session.burned_subtitle}
              checked={(track) => (track.burn ? track.id === session.burned_subtitle : track.id === subtitleId && !session.burned_subtitle)}
              label={(track) => (track.burn ? `${subtitleLabel(track)} (drawn in; converts the video)` : subtitleLabel(track))}
              onOff={() => {
                setSubtitleId(null);
                rememberSubtitle(null);
                if (session.burned_subtitle) onChooseBurn(null, video.current?.currentTime ?? playhead.get());
              }}
              onPick={(track) => {
                const position = video.current?.currentTime ?? playhead.get();
                if (track.burn) {
                  setSubtitleId(null);
                  if (track.stream_index !== null) onChooseBurn(track.stream_index, position);
                  return;
                }
                setSubtitleId(track.id);
                rememberSubtitle(track);
                if (session.burned_subtitle) onChooseBurn(null, position);
              }}
            />
            <AudioMenu
              tracks={session.media_file?.audio ?? []}
              current={session.audio_stream_index}
              onChoose={(index) => onChooseAudio(index, video.current?.currentTime ?? playhead.get())}
            />
            <PipPicker playing={{ kind: "title", playable: item.kind, id: item.id, title: session.title }} />
            <SettingsMenu
              rate={rate}
              onRate={setRate}
              levelling={audioPrefs.levelling}
              night={audioPrefs.night}
              nightDisabled={!audioGraph && !(safariHls && hasMediaSource())}
              onAudio={changeAudio}
              fillWindow={inline ? fillWindow : null}
              onFillWindow={changeFillWindow}
            />
            {inline ? (
              <IconButton label={size === "normal" ? "Full Width (t)" : "Normal (t)"} size="lg" onClick={toggleSize}>
                {size === "normal" ? <UnfoldHorizontal className="h-5 w-5" aria-hidden /> : <FoldHorizontal className="h-5 w-5" aria-hidden />}
              </IconButton>
            ) : null}
            <FullscreenButton fullscreen={fullscreen} onToggle={toggleFullscreen} />
          </div>
        </div>
        {showKeys ? <KeySheet onClose={() => setShowKeys(false)} /> : null}
      </div>
      ) : null}
      {/* Outside the fading controls: open, it stays until closed. */}
      {full && showRelated ? <RelatedPanel item={item} session={session} onClose={() => setShowRelated(false)} /> : null}
    </div>
  );
}
