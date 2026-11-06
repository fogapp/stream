import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { matchPath, useLocation, useNavigate } from "react-router-dom";
import { api, apiErrorMessage } from "@/api/client";
import { prefetchedSessions, pressedTitle } from "@/lib/prefetch";
import { Player } from "@/components/player/Player";
import { ResumeCard } from "@/components/player/ResumeCard";
import { useAnchorBox } from "@/components/player/anchor";
import { LivePicture } from "@/components/pip/LivePicture";
import { leavePlayer, reportFallingBehind, reportPlayFailure } from "@/components/player/failure";
import { fromTv, tvPath } from "@/lib/tv";
import { installAudioPriming } from "@/components/player/audio";
import { markRequested, requestedAt, type StartMark } from "@/components/player/timing";
import { usePlayQueue } from "@/hooks/usePlayQueue";
import { useResumeOffer } from "@/hooks/useResumeOffer";
import { isTypingTarget } from "@/lib/keys";
import { storedSize, storeSize, type PlayerSize } from "@/lib/playerSize";
import { liveHandoff } from "@/lib/liveHandoff";
import { createSession, readyInMs, releaseSession } from "@/lib/playbackSession";
import { handoffKey, heardToo, hears, livePath, sameSource, type PipAudio, type PipSource } from "@/lib/pip";
import type { NextItem, PlaybackSessionInfo, PlayableKind } from "@/types";

interface Current {
  kind: PlayableKind;
  id: string;
  session: PlaybackSessionInfo;
  startAt: number;
  /** When it was asked for and answered: the start of its startup timing. */
  mark: StartMark;
}

type LiveSource = Extract<PipSource, { kind: "station" | "stream" }>;

/** The inset (picture in picture): a title playing in a player of its own, or a channel or a stream. */
type Pip = { kind: "title"; current: Current } | LiveSource;

function titleSource(current: Current): PipSource {
  return { kind: "title", playable: current.kind, id: current.id, title: current.session.title };
}

function pipSource(pip: Pip): PipSource {
  return pip.kind === "title" ? titleSource(pip.current) : pip;
}

/** A session asked for this soon before it's played was asked for by the press itself. */
const PRESS_WINDOW_MS = 5_000;

interface Playback {
  current: Current | null;
  pending: boolean;
  /** The server is getting the title ready to stream (its keyframe index): it's asked again by itself. */
  preparing: boolean;
  error: string | null;
  /** Start (or keep) playing this title. A title already playing just carries on. */
  play: (kind: PlayableKind, id: string, options?: PlayOptions) => void;
  close: () => void;
  /** Play next (PROPOSAL §5.4): what plays after this, ahead of Up next. */
  queue: NextItem[];
  enqueue: (item: NextItem) => void;
  /** Everything queued, replaced by these, in this order (Shuffle). */
  replaceQueue: (items: NextItem[]) => void;
  dequeue: (id: string) => void;
  size: PlayerSize;
  setSize: (size: PlayerSize) => void;
  /** A page's place for this video's player; the player is laid over it while it plays. */
  setSlot: (id: string, element: HTMLElement | null) => void;
  /** Jump what's playing to here, if it's this title. */
  seek: (id: string, at: number) => boolean;
  /** What's in the inset over the main picture (picture in picture), if anything. */
  pip: PipSource | null;
  /** Something else in the inset, over whatever plays: it starts silent. */
  openPip: (source: PipSource, options?: { keepSound?: boolean }) => void;
  closePip: () => void;
  /** The inset and the main picture trade places. */
  swapPip: () => void;
  /** Whose sound plays while there's an inset. */
  pipAudio: PipAudio;
  setPipAudio: (audio: PipAudio) => void;
  /** The main picture is quiet because the inset's sound was chosen. */
  mainSilenced: boolean;
  /** The main picture was unmuted while silenced: both, then. */
  hearMain: () => void;
  /** A channel's or a stream's page, saying it's the main picture; the returned function says it's gone. */
  registerLiveMain: (source: LiveSource) => () => void;
}

interface PlayOptions {
  fromStart?: boolean;
  /** A particular version (PROPOSAL §4.2), rather than the best one here. */
  mediaFileId?: string;
  /** Playing through a playlist: Up next follows it. */
  playlistId?: string;
  /** Start here (seconds), e.g. from a timestamp in a description. */
  startAt?: number;
}

const PlaybackContext = createContext<Playback | null>(null);

/** Prefetched sessions are for a title in a context: alone, or in a playlist. */
function prefetchKey(kind: PlayableKind, id: string, playlistId?: string | null) {
  return `${kind}:${id}:${playlistId ?? ""}`;
}

/** Where the player for this title lives. */
function watchPath(kind: PlayableKind, id: string, playlistId?: string | null) {
  return `/watch/${kind}/${id}${playlistId ? `?playlist=${playlistId}` : ""}`;
}

function startSession(
  kind: PlayableKind,
  id: string,
  options: { audioIndex?: number; start?: number; mediaFileId?: string; playlistId?: string | null; burnSubtitle?: number | null } = {},
) {
  return markRequested(createSession({
    playable_type: kind,
    playable_id: id,
    audio_index: options.audioIndex,
    burn_subtitle: options.burnSubtitle ?? undefined,
    start: options.start,
    media_file_id: options.mediaFileId,
    playlist_id: options.playlistId ?? undefined,
  }));
}

/**
 * Owns what's playing, above the router (PROPOSAL §7.3): the player lives
 * here rather than in the Watch page, so leaving the page shrinks it into a
 * mini-player instead of stopping it. Full screen on /watch/…, in the page
 * on a video's own, a corner everywhere else — and expanded from the corner,
 * full screen over whatever page it was on, which is there again after.
 */
export function PlaybackProvider({ children }: { children: ReactNode }) {
  const navigate = useNavigate();
  const location = useLocation();
  const [current, setCurrent] = useState<Current | null>(null);
  const [pending, setPending] = useState(false);
  const [preparing, setPreparing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const { queue, keepQueue, enqueue, dequeue } = usePlayQueue();
  const [size, setSizeState] = useState<PlayerSize>(storedSize);
  const [slot, setSlotState] = useState<{ id: string; element: HTMLElement } | null>(null);
  const [seekRequest, setSeekRequest] = useState<{ at: number; nonce: number } | null>(null);
  // Expanded from the corner: full window over whatever page this is, so
  // going back to the corner finds that page as it was left.
  const [expanded, setExpanded] = useState(false);
  const request = useRef(0);
  // Picture in picture: what's in the inset, whose sound plays, and the
  // main picture when it's a channel's or a stream's page rather than a title.
  const [pip, setPip] = useState<Pip | null>(null);
  const [pipAudio, setPipAudio] = useState<PipAudio>("main");
  const [liveMain, setLiveMain] = useState<LiveSource | null>(null);
  const pipRequest = useRef(0);
  const setSize = useCallback((next: PlayerSize) => {
    setSizeState(next);
    storeSize(next);
  }, []);
  const setSlot = useCallback((id: string, element: HTMLElement | null) => {
    setSlotState((previous) => {
      if (element) return previous?.id === id && previous.element === element ? previous : { id, element };
      return previous?.id === id ? null : previous;
    });
  }, []);
  /** The title being started, so asking twice (Strict Mode) starts it once. */
  const starting = useRef<string | null>(null);

  const retryTimer = useRef<number | undefined>(undefined);
  // Read when a start fails: whether the viewer is on its full-screen route, and the way off it.
  const pathname = useRef(location.pathname);
  pathname.current = location.pathname;
  const navigateRef = useRef(navigate);
  navigateRef.current = navigate;
  useEffect(() => () => window.clearTimeout(retryTimer.current), []);

  /** Whatever was being started, forgotten: its answer is dropped when it comes. */
  const cancelLoad = useCallback(() => {
    request.current += 1;
    window.clearTimeout(retryTimer.current);
    starting.current = null;
    setPending(false);
    setPreparing(false);
    setError(null);
  }, []);

  const load = useCallback(
    (
      kind: PlayableKind,
      id: string,
      session: Promise<PlaybackSessionInfo>,
      startAt?: (session: PlaybackSessionInfo) => number,
      /** Asks for the session again, when the server says to try again shortly (Retry-After). */
      again?: () => Promise<PlaybackSessionInfo>,
    ) => {
      const ticket = (request.current += 1);
      window.clearTimeout(retryTimer.current);
      starting.current = `${kind}:${id}`;
      setPending(true);
      setError(null);
      // The press is when the session was asked for — unless that was long
      // before (Up next warmed it during the credits): then it's now.
      const pressed = performance.now();
      const early = requestedAt(session);
      const asked = early !== null && pressed - early < PRESS_WINDOW_MS ? early : pressed;
      session
        .then((info) => {
          const mark = { requestedAt: asked, answeredAt: performance.now() };
          // Overtaken by something else: end it, so a conversion nobody is
          // watching doesn't hold one of the server's slots.
          if (ticket !== request.current) {
            releaseSession(info);
            return;
          }
          setCurrent({ kind, id, session: info, startAt: startAt ? startAt(info) : info.resume_at, mark });
          reportFallingBehind(info);
        })
        .catch((failure: unknown) => {
          if (ticket !== request.current) return;
          // Not ready to stream yet (its keyframe index is being built):
          // ask again when the server said to, the clock still running from the press.
          const ready = readyInMs(failure);
          if (again && ready !== null) {
            setPreparing(true);
            retryTimer.current = window.setTimeout(() => {
              if (ticket === request.current) load(kind, id, markRequested(again(), asked), startAt, again);
            }, ready);
            return "retrying" as const;
          }
          const message = apiErrorMessage(failure, "This couldn't be played.");
          setError(message);
          reportPlayFailure(null, message);
          // Nothing to show on its full-screen route: back to the title.
          const watching = matchPath("/watch/:kind/:id", pathname.current)?.params.id === id;
          if (watching) leavePlayer(navigateRef.current, kind, id);
        })
        .then((outcome) => {
          if (ticket !== request.current || outcome === "retrying") return;
          starting.current = null;
          setPending(false);
          setPreparing(false);
        });
    },
    [],
  );

  const play = useCallback(
    (kind: PlayableKind, id: string, options: PlayOptions = {}) => {
      // What's in the inset, played: it comes out to be the main picture, carrying on.
      if (pip?.kind === "title" && pip.current.kind === kind && pip.current.id === id) {
        pipRequest.current += 1;
        setPip(null);
        const simple = !options.fromStart && !options.mediaFileId && !options.playlistId && options.startAt === undefined;
        if (simple) {
          cancelLoad();
          setCurrent(pip.current);
          return;
        }
      }
      const sameVersion = !options.mediaFileId || current?.session.media_file?.id === options.mediaFileId;
      const sameList = (options.playlistId ?? null) === (current?.session.playlist_id ?? null);
      if (current && current.kind === kind && current.id === id && !options.fromStart && sameVersion && sameList && options.startAt === undefined) return;
      if (starting.current === `${kind}:${id}`) return;
      const startAt = options.startAt;
      if (startAt !== undefined) {
        const again = () => startSession(kind, id, { start: startAt, mediaFileId: options.mediaFileId, playlistId: options.playlistId });
        load(kind, id, again(), () => startAt, again);
        return;
      }
      const again = () => startSession(kind, id, { mediaFileId: options.mediaFileId, playlistId: options.playlistId });
      const session = options.mediaFileId ? again() : (prefetchedSessions.take(prefetchKey(kind, id, options.playlistId)) ?? again());
      load(kind, id, session, options.fromStart ? () => 0 : undefined, again);
    },
    [current, load, pip, cancelLoad],
  );

  const { resumable, resuming, remember, resume, dismiss, forget } = useResumeOffer(current, error, play);

  const close = useCallback(() => {
    forget();
    cancelLoad();
    setCurrent(null);
  }, [forget, cancelLoad]);

  // A press on anything that plays a title starts its session there and
  // then, while the page changes (docs/PERF_PROPOSAL.md › P6): the watch
  // page takes it up as a prefetched session. The same press is the
  // gesture that starts the shared AudioContext (P22).
  const currentRef = useRef(current);
  currentRef.current = current;
  useEffect(() => {
    const stopPriming = installAudioPriming();
    const onPress = (event: Event) => {
      if (event instanceof KeyboardEvent && event.key !== "Enter" && event.key !== " ") return;
      if (event instanceof PointerEvent && event.button !== 0) return;
      const title = pressedTitle(event.target);
      if (!title) return;
      const playing = currentRef.current;
      if (playing && playing.kind === title.kind && playing.id === title.id) return;
      const key = prefetchKey(title.kind, title.id, title.playlistId);
      if (prefetchedSessions.has(key)) return;
      prefetchedSessions.put(key, startSession(title.kind, title.id, { playlistId: title.playlistId }));
    };
    document.addEventListener("pointerdown", onPress, true);
    document.addEventListener("keydown", onPress, true);
    return () => {
      stopPriming();
      document.removeEventListener("pointerdown", onPress, true);
      document.removeEventListener("keydown", onPress, true);
    };
  }, []);

  // Not over the full-screen player's own route, the TV layout, or live TV.
  const offerResume =
    resumable !== null &&
    !current &&
    (resuming || !pending) &&
    !/^\/(watch|tv)(\/|$)|^\/live\/[^/]+$/.test(location.pathname) &&
    !(location.pathname === "/live/channels");

  const full = current ? matchPath("/watch/:kind/:id", location.pathname)?.params.id === current.id : false;
  // On its own page, a video plays in the page (PROPOSAL §5.4).
  const inline = !full && current?.kind === "video" && slot?.id === current.id;
  const overlay = expanded && !full && !inline;
  const mainMode = full || overlay ? "full" : inline ? "inline" : "mini";
  // The inset is kept inside the main title's picture: in its page's slot
  // (scrolling with the page), or full window beside the Related panel. A
  // channel's or a stream's page fills the window.
  const [mainVideo, setMainVideo] = useState<HTMLVideoElement | null>(null);
  const insetInPage = inline && size !== "window";
  const insetBox = useAnchorBox(pip && current && !liveMain ? mainVideo : null, { page: insetInPage });
  const insetArea = useMemo(() => (insetBox ? { box: insetBox, page: insetInPage } : null), [insetBox, insetInPage]);

  // Nothing to expand, or it has a place of its own now.
  useEffect(() => {
    if (!current || full || inline) setExpanded(false);
  }, [current, full, inline]);
  // Escape, while browsing with a title in the corner, closes it — unless
  // something on the page is open that Escape closes first (a dialog, a
  // menu, the navigation drawer) or the key is someone's typing. Capture
  // phase, so those are still in the page when this looks.
  const miniOpen = current !== null && !liveMain && mainMode === "mini";
  useEffect(() => {
    if (!miniOpen) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented || document.fullscreenElement) return;
      if (isTypingTarget(event.target)) return;
      if (document.querySelector('[role="dialog"], [role="menu"], [role="listbox"], [data-overlay]')) return;
      close();
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [miniOpen, close]);

  // The page underneath holds still while the player is over it.
  useEffect(() => {
    if (!overlay) return;
    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = previous;
    };
  }, [overlay]);

  const seek = useCallback(
    (id: string, at: number) => {
      if (current?.id !== id) return false;
      setSeekRequest((previous) => ({ at, nonce: (previous?.nonce ?? 0) + 1 }));
      return true;
    },
    [current],
  );
  // A seek asked of one session isn't for the next.
  useEffect(() => setSeekRequest(null), [current?.session.id]);

  const mainSource = useMemo(() => liveMain ?? (current ? titleSource(current) : null), [liveMain, current]);
  const insetSource = useMemo(() => (pip ? pipSource(pip) : null), [pip]);

  const closePip = useCallback(() => {
    pipRequest.current += 1;
    setPip(null);
  }, []);

  const openPip = useCallback(
    (source: PipSource, { keepSound = false }: { keepSound?: boolean } = {}) => {
      if (sameSource(source, mainSource) || sameSource(source, insetSource)) return;
      // A title in the corner comes back over the page, the inset over it:
      // one floating picture at a time.
      if (current && !liveMain && mainMode === "mini") setExpanded(true);
      const sound = () => {
        if (!keepSound) setPipAudio("main");
      };
      // Full screen on the player alone would hide the inset: the whole page
      // instead, while this is still the press that asked. The browser won't
      // hand full screen up to an ancestor, so it's left first.
      const fullscreen = document.fullscreenElement;
      if (fullscreen && fullscreen !== document.documentElement) {
        void document
          .exitFullscreen()
          .then(() => document.documentElement.requestFullscreen())
          .catch(() => undefined);
      }
      const ticket = (pipRequest.current += 1);
      if (source.kind !== "title") {
        setPip(source);
        sound();
        return;
      }
      const ask = (requestedAt: number) => {
        startSession(source.playable, source.id)
          .then((session) => {
            if (ticket !== pipRequest.current) {
              releaseSession(session);
              return;
            }
            setPip({ kind: "title", current: { kind: source.playable, id: source.id, session, startAt: session.resume_at, mark: { requestedAt, answeredAt: performance.now() } } });
            sound();
          })
          .catch((failure: unknown) => {
            if (ticket !== pipRequest.current) return;
            // Being made ready to stream: asked again when the server says.
            const ready = readyInMs(failure);
            if (ready !== null) {
              window.setTimeout(() => {
                if (ticket === pipRequest.current) ask(requestedAt);
              }, ready);
              return;
            }
            reportPlayFailure(source.title || null, apiErrorMessage(failure, "This couldn't be played in picture in picture."));
          });
      };
      ask(performance.now());
    },
    [mainSource, insetSource, current, liveMain, mainMode],
  );

  // The pictures trade places. A title keeps its player (only its place
  // changes); a channel or a stream is handed between its page and the
  // inset still playing. The sound stays with the place: whatever is main
  // now is heard as the main picture was.
  const swapPip = useCallback(() => {
    if (!pip) return;
    const mainTitle = liveMain ? null : current;
    liveHandoff.swapping(...[pip.kind === "title" ? null : handoffKey(pip), liveMain ? handoffKey(liveMain) : null].filter((key): key is string => key !== null));
    pipRequest.current += 1;
    // Where the main picture had the whole window, the new one does too.
    const replace = Boolean(liveMain) || full;
    if (pip.kind === "title") {
      const next = pip.current;
      cancelLoad();
      setCurrent(next);
      setLiveMain(null);
      // From a video's own page too: the page holds that video, not this one.
      if (replace || !mainTitle || inline) navigate(watchPath(next.kind, next.id, next.session.playlist_id), { replace });
    } else {
      setCurrent(null);
      setLiveMain(pip);
      navigate(livePath(pip), { replace });
    }
    setPip(liveMain ?? (mainTitle ? { kind: "title", current: mainTitle } : null));
  }, [pip, liveMain, current, full, inline, navigate, cancelLoad]);

  const registerLiveMain = useCallback((source: LiveSource) => {
    setLiveMain((previous) => (previous && sameSource(previous, source) && previous.title === source.title ? previous : source));
    return () => setLiveMain((previous) => (previous && sameSource(previous, source) ? null : previous));
  }, []);

  // The main title shrinking into the corner stops the inset: one floating
  // picture at a time. (A title just swapped in may pass through the
  // corner before its route catches up: only the same session moving counts.)
  const mainPlace = useRef<{ session: string; mode: typeof mainMode } | null>(null);
  useEffect(() => {
    const was = mainPlace.current;
    mainPlace.current = current ? { session: current.session.id, mode: mainMode } : null;
    if (pip && current && !liveMain && mainMode === "mini" && was?.session === current.session.id && was.mode !== "mini") closePip();
  }, [current, mainMode, pip, liveMain, closePip]);

  // The main picture became what's in the inset: one of it is enough.
  useEffect(() => {
    if (insetSource && sameSource(mainSource, insetSource)) closePip();
  }, [mainSource, insetSource, closePip]);

  // A play carried on as another session: a rung down when it failed, or back up when it fell for a passing
  // reason. The new session takes the old one's place — main or inset — if
  // it's still there; a rung that isn't (409) rejects with why.
  const carryOn = useCallback(
    (from: Current, place: "main" | "pip", path: "fallback" | "upgrade", body: Record<string, unknown>) =>
      api.post<PlaybackSessionInfo | undefined>(`/playback_sessions/${from.session.id}/${path}`, body).then((info) => {
        if (!info) return;
        const now = performance.now();
        const next: Current = { kind: from.kind, id: from.id, session: info, startAt: info.resume_at, mark: { requestedAt: now, answeredAt: now } };
        if (place === "main") setCurrent((playing) => (playing?.session.id === from.session.id ? next : playing));
        else setPip((inset) => (inset?.kind === "title" && inset.current.session.id === from.session.id ? { kind: "title", current: next } : inset));
      }),
    [],
  );

  const hearMain = useCallback(() => setPipAudio((audio) => heardToo(audio, "main")), []);
  const hearPip = useCallback(() => setPipAudio((audio) => heardToo(audio, "pip")), []);
  const mainSilenced = pip !== null && !hears(pipAudio, "main");
  const pipHeard = hears(pipAudio, "pip");

  // X swaps, wherever the keys are.
  useEffect(() => {
    if (!pip) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "x" || event.metaKey || event.ctrlKey || event.altKey) return;
      if (isTypingTarget(event.target)) return;
      event.preventDefault();
      swapPip();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [pip, swapPip]);

  const value = useMemo(
    () => ({
      current,
      pending,
      preparing,
      error,
      play,
      close,
      queue,
      enqueue,
      replaceQueue: keepQueue,
      dequeue,
      size,
      setSize,
      setSlot,
      seek,
      pip: insetSource,
      openPip,
      closePip,
      swapPip,
      pipAudio,
      setPipAudio,
      mainSilenced,
      hearMain,
      registerLiveMain,
    }),
    [current, pending, preparing, error, play, close, queue, enqueue, keepQueue, dequeue, size, setSize, setSlot, seek, insetSource, openPip, closePip, swapPip, pipAudio, mainSilenced, hearMain, registerLiveMain],
  );
  // What's queued plays before whatever the session would have offered.
  const upNext = queue.find((item) => item.id !== current?.id) ?? null;

  // The main title and the inset's, side by side and keyed by session: a
  // swap only changes each one's place, so neither picture starts over.
  // (In a steady order, so a swap never moves a playing element either.)
  const titles = [
    current ? { place: "main" as const, playing: current } : null,
    pip?.kind === "title" ? { place: "pip" as const, playing: pip.current } : null,
  ]
    .filter((entry) => entry !== null)
    .sort((a, b) => (a.playing.session.id < b.playing.session.id ? -1 : 1));
  const noop = () => undefined;
  /** Another way to play it, from where it is: a new session takes over. */
  const restartAt = (playing: Current, position: number, change: { audioIndex?: number; burnSubtitle?: number | null }) => {
    const again = () =>
      startSession(playing.kind, playing.id, { start: position, mediaFileId: playing.session.media_file?.id, playlistId: playing.session.playlist_id, ...change });
    load(playing.kind, playing.id, again(), () => position, again);
  };

  return (
    <PlaybackContext.Provider value={value}>
      {children}
      {titles.map(({ place, playing }) =>
        place === "pip" ? (
          <Player
            key={playing.session.id}
            item={{ kind: playing.kind, id: playing.id }}
            session={playing.session}
            startAt={playing.startAt}
            mark={playing.mark}
            mode="pip"
            silenced={!pipHeard}
            onUnsilence={hearPip}
            inset={{ audio: pipAudio, onAudio: setPipAudio, onSwap: swapPip, area: insetArea }}
            onChooseAudio={noop}
            onChooseBurn={noop}
            onPrefetch={noop}
            // The next episode plays on in the inset.
            onNext={(next) => openPip({ kind: "title", playable: next.kind, id: next.id, title: next.title ?? "" }, { keepSound: true })}
            onFallback={(failure, position) => carryOn(playing, "pip", "fallback", { failure_class: failure.failureClass, cause: failure.cause, position })}
            onUpgrade={(position) => carryOn(playing, "pip", "upgrade", { position })}
            onFailed={(message) => {
              reportPlayFailure(playing.session.title, message);
              closePip();
            }}
            onClose={closePip}
          />
        ) : (
          <Player
            key={playing.session.id}
            item={{ kind: playing.kind, id: playing.id }}
            session={upNext ? { ...playing.session, next_up: upNext } : playing.session}
            startAt={playing.startAt}
            mark={playing.mark}
            mode={mainMode}
            onBack={overlay ? () => setExpanded(false) : undefined}
            anchor={inline ? (slot?.element ?? null) : null}
            size={size}
            onSize={setSize}
            seekRequest={seekRequest}
            silenced={mainSilenced}
            onUnsilence={hearMain}
            insetUp={pip !== null}
            onVideo={setMainVideo}
            onChooseAudio={(audioIndex, position) => restartAt(playing, position, { audioIndex })}
            onChooseBurn={(streamIndex, position) =>
              restartAt(playing, position, { audioIndex: playing.session.audio_stream_index ?? undefined, burnSubtitle: streamIndex })
            }
            onPrefetch={(next) =>
              prefetchedSessions.put(prefetchKey(next.kind, next.id, next.playlist_id), startSession(next.kind, next.id, { playlistId: next.playlist_id }))
            }
            onNext={(next) => {
              dequeue(next.id);
              if (full || (inline && next.kind !== "video")) navigate(watchPath(next.kind, next.id, next.playlist_id), { replace: true });
              else {
                // The page follows the video playing in it.
                if (inline) navigate(`/video/${next.id}`);
                const again = () => startSession(next.kind, next.id, { playlistId: next.playlist_id });
                load(next.kind, next.id, prefetchedSessions.take(prefetchKey(next.kind, next.id, next.playlist_id)) ?? again(), undefined, again);
              }
            }}
            onReport={(position, duration, still) => remember(playing.session.id, position, duration, still)}
            onFallback={(failure, position) => carryOn(playing, "main", "fallback", { failure_class: failure.failureClass, cause: failure.cause, position })}
            onUpgrade={(position) => carryOn(playing, "main", "upgrade", { position })}
            onFailed={(message) => {
              reportPlayFailure(playing.session.title, message);
              // Off the full-screen route to the title's page, which Back doesn't return from.
              if (full) navigate(fromTv() ? tvPath(playing.session.back_path) : playing.session.back_path, { replace: true });
              setExpanded(false);
              close();
            }}
            onExpand={() => setExpanded(true)}
            onClose={() => {
              setExpanded(false);
              close();
            }}
          />
        ),
      )}
      {!current && offerResume ? (
        <ResumeCard item={resumable} starting={resuming && pending} onResume={resume} onDismiss={dismiss} />
      ) : null}
      {pip && pip.kind !== "title" ? (
        <LivePicture key={handoffKey(pip)} source={pip} audio={pipAudio} heard={pipHeard} onAudio={setPipAudio} onSwap={swapPip} onClose={closePip} area={insetArea} />
      ) : null}
    </PlaybackContext.Provider>
  );
}

export function usePlayback(): Playback {
  const context = useContext(PlaybackContext);
  if (!context) throw new Error("usePlayback outside PlaybackProvider");
  return context;
}
