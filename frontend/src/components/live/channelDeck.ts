import { api, ApiError } from "@/api/client";
import { recoveryLog } from "@/components/player/recoveries";
import { playOrMute } from "@/components/player/audio";
import { attachSource } from "@/components/player/source";
import { onFirstFrame } from "@/components/player/timing";
import { prefersNativeHls } from "@/lib/capabilities";
import { clockSkew, gapWait, keepLiveTarget, liveOffset } from "@/lib/live";
import { liveHandoff } from "@/lib/liveHandoff";
import { createSession, postEvents, releaseSession } from "@/lib/playbackSession";
import { viewerMuted } from "@/lib/volume";
import type { PlaybackSessionInfo } from "@/types";

/** A standby channel is nudged back to live this often, so switching lands inside what it has buffered. */
const KEEP_LIVE_MS = 8_000;
/** Buffered ahead on standby: enough to cover a nudge's worth of live moving on (docs/PERF_PROPOSAL.md › P21). */
const STANDBY_BUFFER_S = 10;
/**
 * Buffered ahead on screen: room for the network or the transcoder to
 * stumble without the picture stopping. A film's GOP can be ten seconds —
 * the standby's ten were one fragment of headroom.
 */
const ON_SCREEN_BUFFER_S = 30;
/** Near enough to live that a nudge would only ask for what's already there. */
const LIVE_SLACK_S = 2;
/** The channel on screen tunes again by itself after a failure, this long after each: then it says so. */
const RETRY_MS = [1_500, 5_000];
/** The next program is tuned ahead, beside the one on screen, once this little of it is left. */
const READY_NEXT_S = 30;
/** How early the next program may start rather than a slate: the server's FOLLOWING_EARLY. */
const FOLLOWING_EARLY_MS = 5_000;

export type SlotState = "tuning" | "ready" | "gap" | "unavailable" | "failed";
/** A channel's two video elements: the one on screen, and the next program readying behind it. */
export type VideoKey = "a" | "b";
/** What noticed a program's end (PlaybackEvent `transition`). */
export type EndedVia = "ended" | "part" | "watchdog";

export type TuneBody = { station_id?: string; airing_id?: string; after_airing_id?: string; start?: number; behind?: number };

/** The program after the one on screen, tuned ahead on the channel's other element. */
interface Upcoming {
  session: PlaybackSessionInfo;
  skew: number;
  /** The airing it follows: only the end of that one plays it. */
  after: string;
  detach: (() => void) | null;
  setBuffer: ((seconds: number) => void) | null;
}

interface Slot {
  stationId: string;
  session: PlaybackSessionInfo | null;
  skew: number;
  state: SlotState;
  /** The server holds it on standby: not yet a play. */
  standby: boolean;
  videos: Record<VideoKey, HTMLVideoElement | null>;
  /** Which of its elements is the one playing. */
  front: VideoKey;
  /** Its second element is in use (kept once it is, so a swap never unmounts what plays). */
  twin: boolean;
  element: HTMLVideoElement | null;
  detach: (() => void) | null;
  /** Its source alone, without the deck's listeners: what a picture handed to the guide takes with it. */
  source: (() => void) | null;
  /** How far ahead its source buffers: more on screen than on standby. */
  setBuffer: ((seconds: number) => void) | null;
  /** Bumped per tune, so an answer for an earlier one is dropped. */
  ticket: number;
  /** Tunes in a row that failed on screen, each tried again (RETRY_MS). */
  failures: number;
  /** A tune waiting to happen: tried again after a failure, or a gap's slate waiting for the next program. */
  retry: number | undefined;
  upcoming: Upcoming | null;
  /** Readying the next program: the airing it's for, while asked (or once refused, so it isn't asked again). */
  readying: string | null;
  /** A program change under way, timed to the next one's first frame. */
  transition: { at: number; via: EndedVia | "gap"; ready: boolean } | null;
}

export interface SlotView {
  stationId: string;
  state: SlotState;
  session: PlaybackSessionInfo | null;
  skew: number;
  /** Its elements to render, and which is on screen. */
  videos: VideoKey[];
  front: VideoKey;
}

const nativeHls = (session: PlaybackSessionInfo) => session.source.kind === "hls" && prefersNativeHls();

const other = (key: VideoKey): VideoKey => (key === "a" ? "b" : "a");

/** Somewhere in a file, or as near its end as it goes: past the end is the end, never back at its start. */
function seekWithin(element: HTMLVideoElement, target: number) {
  const end = Number.isFinite(element.duration) ? Math.max(element.duration - 0.5, 0) : target;
  const at = Math.min(target, end);
  if (at > 0 && Math.abs(element.currentTime - at) > 0.25) element.currentTime = at;
}

function newSlot(stationId: string, standby: boolean): Slot {
  return {
    stationId,
    session: null,
    skew: 0,
    state: "tuning",
    standby,
    videos: { a: null, b: null },
    front: "a",
    twin: false,
    element: null,
    detach: null,
    source: null,
    setBuffer: null,
    ticket: 0,
    failures: 0,
    retry: undefined,
    upcoming: null,
    readying: null,
    transition: null,
  };
}

/**
 * The channels a Grid page holds (PROPOSAL §7.7): the one on screen, and
 * its neighbours tuned ahead on standby — each with its own video element,
 * buffered at live and muted — so changing to one is showing it rather
 * than starting it. A neighbour that would need converting isn't tuned
 * ahead. Every change is timed and reported (a `tune` event). The page can
 * have the first channel on screen tuned to a place behind live instead (a
 * reload coming back to where it was). Left for the
 * guide (`toGuide` says so, as the page goes), the channel on screen is
 * handed to the guide's preview instead of let go.
 *
 * The program on screen gives way to the next the same way: as it nears its
 * end the next is tuned ahead on the channel's second element, and at the
 * end (`advance`) that element comes to the front. Between programs the
 * slate waits for the next to start — the server says when — and every
 * change is timed and reported (a `transition` event).
 *
 * No React in here: useChannelDeck holds one for a page, and says when the
 * line-up changes and the page goes. `dispose` leaves it ready to be given a
 * line-up again, since Strict Mode's rehearsal does exactly that.
 */
export class ChannelDeck {
  private readonly slots = new Map<string, Slot>();
  private readonly binders = new Map<string, (element: HTMLVideoElement | null) => void>();
  private readonly listeners = new Set<() => void>();
  private version = 0;
  private switchedAt: { at: number; ready: boolean; stationId: string } | null = null;
  private parked: HTMLVideoElement | null = null;
  private activeId: string | null;
  /** Going to the guide: the page says, as it goes. */
  toGuide: (() => boolean) | undefined;
  /** An airing and a place in it to tune a channel to when it first comes on screen, rather than live (a reload's way back). */
  resume: ((stationId: string) => TuneBody | null) | undefined;

  constructor(activeId: string | null) {
    this.activeId = activeId;
  }

  readonly subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };

  /** Moves whenever there's something new to show. */
  readonly getVersion = () => this.version;

  private rerender() {
    this.version += 1;
    for (const listener of this.listeners) listener();
  }

  views(): SlotView[] {
    return [...this.slots.values()].map((slot) => ({
      stationId: slot.stationId,
      state: slot.state,
      session: slot.session,
      skew: slot.skew,
      videos: slot.twin ? ["a", "b"] : ["a"],
      front: slot.front,
    }));
  }

  elementOf(stationId: string | null) {
    return (stationId ? this.slots.get(stationId)?.element : null) ?? null;
  }

  private isActive(slot: Slot) {
    return slot.stationId === this.activeId;
  }

  private play(slot: Slot) {
    const element = slot.element;
    if (!element) return;
    element.muted = viewerMuted();
    playOrMute(element);
  }

  // Seconds into the file where live is: a part of a program starts partway in.
  // A stream (a game on a channel, too) has no file: it opens at its newest.
  private liveAt(slot: Slot) {
    if (slot.session?.live_stream) return 0;
    const live = slot.session?.live;
    return live ? live.media_start + liveOffset(live, Date.now() + slot.skew) : 0;
  }

  /** A session's source on an element, from a place in it; `onMeta` once it knows the file. */
  private connect(
    element: HTMLVideoElement,
    session: PlaybackSessionInfo,
    from: number,
    buffer: number,
    handlers: { onFailed: (message: string | null) => void; onMeta: () => void },
  ) {
    const recovered = recoveryLog((recoveries) => postEvents(session.events_url, recoveries.map(({ position, ...detail }) => ({ kind: "recovery", position, detail }))));
    const attached = attachSource(
      element,
      session.source,
      from,
      nativeHls(session),
      {
        onUnsupported: () => handlers.onFailed(null),
        onFailure: ({ cause: message }) => {
          recovered.flush();
          postEvents(session.events_url, [{ kind: "error", position: element.currentTime, detail: { message } }]);
          handlers.onFailed(message);
        },
        onRecovery: (what, cause) => recovered.add(what, element.currentTime, cause),
      },
      // A stream's channel (PROPOSAL §7.8) is a live playlist: it opens at its newest.
      { maxBufferLength: buffer, live: Boolean(session.live_stream) },
    );
    element.addEventListener("loadedmetadata", handlers.onMeta, { once: true });
    return {
      detach: () => {
        element.removeEventListener("loadedmetadata", handlers.onMeta);
        recovered.flush();
        attached.detach();
      },
      setBuffer: attached.setBufferLength,
    };
  }

  /** A program change: timed from the old one's end to this one's first frame. */
  private timeTransition(slot: Slot, element: HTMLVideoElement, session: PlaybackSessionInfo, ready?: boolean) {
    const transition = slot.transition;
    if (!transition) return;
    onFirstFrame(element, () => {
      if (slot.transition !== transition || slot.session !== session) return;
      slot.transition = null;
      postEvents(session.events_url, [{ kind: "transition", position: element.currentTime, detail: { ms: Math.round(performance.now() - transition.at), via: transition.via, ready: ready ?? transition.ready } }]);
    });
  }

  private attach(slot: Slot, from: number) {
    const { element, session } = slot;
    if (!element || !session || slot.detach) return;
    element.muted = !this.isActive(slot) || viewerMuted();
    const onReadyNext = () => this.readyNext(slot);
    const connected = this.connect(element, session, from, this.isActive(slot) ? ON_SCREEN_BUFFER_S : STANDBY_BUFFER_S, {
      onFailed: (message) => {
        if (message === null) {
          slot.state = "failed";
          this.rerender();
        } else this.failed(slot);
      },
      onMeta: () => {
        seekWithin(element, this.isActive(slot) ? from : this.liveAt(slot));
        if (this.isActive(slot)) this.play(slot);
      },
    });
    element.addEventListener("timeupdate", onReadyNext);
    slot.detach = () => {
      element.removeEventListener("timeupdate", onReadyNext);
      connected.detach();
    };
    slot.source = connected.detach;
    slot.setBuffer = connected.setBuffer;
    this.timeTransition(slot, element, session);
  }

  /** Let go of the next program tuned ahead, if there is one. */
  private dropUpcoming(slot: Slot) {
    const upcoming = slot.upcoming;
    slot.upcoming = null;
    slot.readying = null;
    if (!upcoming) return;
    upcoming.detach?.();
    releaseSession(upcoming.session);
  }

  /** The next program's session on the channel's spare element, buffering where it will start, paused and silent. */
  private attachUpcoming(slot: Slot) {
    const upcoming = slot.upcoming;
    const element = slot.videos[other(slot.front)];
    if (!upcoming || upcoming.detach || !element) return;
    element.muted = true;
    const from = upcoming.session.resume_at;
    const connected = this.connect(element, upcoming.session, from, STANDBY_BUFFER_S, {
      // It may yet play the ordinary way, tuned at the end.
      onFailed: () => {
        if (slot.upcoming !== upcoming) return;
        slot.upcoming = null;
        upcoming.detach?.();
        releaseSession(upcoming.session);
      },
      onMeta: () => seekWithin(element, from),
    });
    upcoming.detach = connected.detach;
    upcoming.setBuffer = connected.setBuffer;
  }

  private release(slot: Slot) {
    slot.detach?.();
    slot.detach = null;
    slot.source = null;
    slot.setBuffer = null;
    const session = slot.session;
    slot.session = null;
    if (session) releaseSession(session);
  }

  /** Wait for a gap in the schedule to end, then tune `body` — or bring forward the next program, if it's tuned ahead. */
  private waitOutGap(slot: Slot, delay: number, body: TuneBody) {
    slot.state = "gap";
    window.clearTimeout(slot.retry);
    slot.retry = window.setTimeout(() => {
      slot.retry = undefined;
      if (this.slots.get(slot.stationId) !== slot) return;
      if (this.isActive(slot)) slot.transition = { at: performance.now(), via: "gap", ready: Boolean(slot.upcoming) };
      if (slot.upcoming && Date.parse(slot.upcoming.session.live?.starts_at ?? "") <= Date.now() + slot.upcoming.skew + FOLLOWING_EARLY_MS) this.promote(slot, 0);
      else this.tune(slot, body, true);
    }, delay);
  }

  private tune(slot: Slot, body: TuneBody, again = false) {
    slot.ticket += 1;
    const ticket = slot.ticket;
    window.clearTimeout(slot.retry);
    slot.retry = undefined;
    if (!again) slot.failures = 0;
    this.dropUpcoming(slot);
    this.release(slot);
    slot.state = "tuning";
    slot.standby = !this.isActive(slot);
    this.rerender();
    // A channel handed over (from the guide's preview, or the inset) is
    // taken on the next tick: Strict Mode's rehearsal unmounts at once,
    // and mustn't spend it.
    let handed: ReturnType<typeof liveHandoff.take> = null;
    const request =
      body.station_id && (liveHandoff.has(slot.stationId) || liveHandoff.isSwapping(slot.stationId))
        ? new Promise<void>((resolve) => window.setTimeout(resolve, 0))
            .then(() => {
              if (ticket !== slot.ticket) throw new Error("overtaken");
              return liveHandoff.receive(slot.stationId);
            })
            .then((received) => {
              handed = received;
              return received ? received.session : createSession({ ...body, standby: slot.standby });
            })
        : createSession({ ...body, standby: slot.standby });
    request
      .then((session) => {
        if (ticket !== slot.ticket || !this.slots.has(slot.stationId)) {
          releaseSession(session);
          return;
        }
        slot.session = session;
        slot.skew = handed ? handed.skew : session.live ? clockSkew(session.live.server_now) : 0;
        slot.state = "ready";
        // A handed-over session was on standby; if this one is on screen, it's a play now.
        if (handed && !slot.standby) void api.post(`/playback_sessions/${session.id}/watch`, { position: session.resume_at }).catch(() => undefined);
        // Where the server said, when asked for somewhere in particular;
        // otherwise wherever live has got to by now.
        // Handed over from the inset, it carries on as far behind live as it was there.
        const placed = body.start !== undefined || body.behind !== undefined || body.after_airing_id !== undefined;
        const at = placed ? session.resume_at : this.liveAt(slot);
        this.attach(slot, handed && !placed && handed.behind > 0 ? Math.max(at - handed.behind, session.live?.media_start ?? 0) : at);
        this.rerender();
      })
      .catch((failure: unknown) => {
        if (ticket !== slot.ticket) return;
        if (failure instanceof ApiError && failure.status === 409) {
          // A gap in the schedule: the slate, until the server says the next starts.
          const wait = gapWait(failure.message, failure.retryAfter);
          if (wait !== null) {
            this.waitOutGap(slot, wait, body.after_airing_id ? body : { station_id: slot.stationId });
            this.rerender();
            return;
          }
          // Its file is being made ready to stream: still tuning, and asked again when the server said.
          if (failure.retryAfter !== null) {
            slot.state = "tuning";
            slot.retry = window.setTimeout(() => {
              slot.retry = undefined;
              if (this.slots.get(slot.stationId) === slot) this.tune(slot, body, true);
            }, failure.retryAfter * 1000);
            this.rerender();
            return;
          }
          slot.state = "unavailable";
          this.rerender();
          return;
        }
        // An airing that's gone (the schedule was edited since): whatever's on now instead.
        if ((body.airing_id || body.after_airing_id) && failure instanceof ApiError && failure.status === 404) {
          this.tune(slot, { station_id: slot.stationId }, true);
          return;
        }
        // Refused outright (this browser can't play it): trying again won't change that.
        const refused = failure instanceof ApiError && failure.status >= 400 && failure.status < 500;
        this.failed(slot, { body, final: refused });
      });
  }

  /**
   * The next program, tuned ahead, to the front: its element shown and
   * played, as far behind live as the viewer was; the one before it let go.
   */
  private promote(slot: Slot, behind: number) {
    const upcoming = slot.upcoming;
    if (!upcoming) return;
    slot.upcoming = null;
    slot.readying = null;
    slot.ticket += 1;
    window.clearTimeout(slot.retry);
    slot.retry = undefined;
    this.release(slot);
    slot.front = other(slot.front);
    slot.element = slot.videos[slot.front];
    slot.session = upcoming.session;
    slot.skew = upcoming.skew;
    slot.state = "ready";
    slot.standby = false;
    slot.failures = 0;
    const element = slot.element;
    const target = Math.max(this.liveAt(slot) - behind, upcoming.session.live?.media_start ?? 0);
    void api.post(`/playback_sessions/${upcoming.session.id}/watch`, { position: target }).catch(() => undefined);
    if (!element || !upcoming.detach) {
      // Its element never got it: attached now, the ordinary way.
      upcoming.detach?.();
      this.attach(slot, target);
      this.rerender();
      return;
    }
    const onReadyNext = () => this.readyNext(slot);
    element.addEventListener("timeupdate", onReadyNext);
    const detachUpcoming = upcoming.detach;
    slot.detach = () => {
      element.removeEventListener("timeupdate", onReadyNext);
      detachUpcoming();
    };
    slot.source = detachUpcoming;
    slot.setBuffer = upcoming.setBuffer;
    slot.setBuffer?.(ON_SCREEN_BUFFER_S);
    if (element.readyState >= 1) seekWithin(element, target);
    this.timeTransition(slot, element, upcoming.session, true);
    this.play(slot);
    this.rerender();
  }

  // As the program on screen nears its end, the next is tuned ahead on the
  // channel's other element — on standby at the server, buffered, paused.
  private readyNext(slot: Slot) {
    const live = slot.session?.live;
    const element = slot.element;
    if (!live?.next_airing_id || !element || slot.state !== "ready" || !this.isActive(slot)) return;
    if (slot.upcoming || slot.readying === live.airing_id || element.paused) return;
    const end = Math.min(live.media_end ?? Infinity, Number.isFinite(element.duration) ? element.duration : Infinity);
    if (!Number.isFinite(end) || end - element.currentTime > READY_NEXT_S) return;
    slot.readying = live.airing_id;
    slot.twin = true;
    this.rerender();
    const ticket = slot.ticket;
    const behind = Math.max(this.liveAt(slot) - element.currentTime, 0);
    createSession({ after_airing_id: live.airing_id, behind, standby: true })
      .then((session) => {
        if (ticket !== slot.ticket || !this.isActive(slot) || slot.readying !== live.airing_id || !this.slots.has(slot.stationId)) {
          releaseSession(session);
          return;
        }
        slot.upcoming = { session, skew: session.live ? clockSkew(session.live.server_now) : slot.skew, after: live.airing_id, detach: null, setBuffer: null };
        this.attachUpcoming(slot);
      })
      .catch((failure: unknown) => {
        // Getting its file ready to stream: asked again when the server said. Otherwise (it would
        // need converting, a long gap follows) it's tuned the ordinary way at the end.
        if (failure instanceof ApiError && failure.retryAfter !== null && gapWait(failure.message, failure.retryAfter) === null) {
          window.setTimeout(() => {
            if (slot.readying === live.airing_id && !slot.upcoming) slot.readying = null;
          }, failure.retryAfter * 1000);
        }
      });
  }

  // A channel that stopped: on screen, it's tuned again a couple of times
  // before saying so (a hiccup at the server, a deploy); off screen, it's
  // tuned again when switched to. Tried again, a program change goes by
  // the channel and the server's clock rather than the airing it was for.
  private failed(slot: Slot, { body = { station_id: slot.stationId }, final = false }: { body?: TuneBody; final?: boolean } = {}) {
    const delay = RETRY_MS[slot.failures];
    if (!final && this.isActive(slot) && delay !== undefined && this.slots.get(slot.stationId) === slot) {
      slot.failures += 1;
      slot.state = "tuning";
      window.clearTimeout(slot.retry);
      // Where live is by then, not where this airing was asked for.
      slot.retry = window.setTimeout(() => {
        slot.retry = undefined;
        this.tune(slot, body.airing_id ? body : { station_id: slot.stationId }, true);
      }, delay);
    } else slot.state = "failed";
    this.rerender();
  }

  /** The line-up: tune what's wanted, let go of the rest. */
  setLineup(activeId: string | null, ids: string[]) {
    const previous = this.activeId;
    this.activeId = activeId;
    for (const [id, slot] of this.slots) {
      if (!ids.includes(id)) {
        slot.ticket += 1;
        window.clearTimeout(slot.retry);
        this.dropUpcoming(slot);
        this.release(slot);
        this.slots.delete(id);
      }
    }
    for (const id of ids) {
      if (!this.slots.has(id)) {
        const slot = newSlot(id, id !== activeId);
        this.slots.set(id, slot);
        this.tune(slot, (id === activeId ? this.resume?.(id) : null) ?? { station_id: id });
      }
    }
    // The one on screen: sound on, at live, playing; the one before it
    // goes quiet and stays buffered for Last.
    if (previous && previous !== activeId) {
      const old = this.slots.get(previous);
      if (old) {
        this.dropUpcoming(old);
        old.transition = null;
      }
      if (old?.element) {
        old.element.muted = true;
        old.element.pause();
      }
      old?.setBuffer?.(STANDBY_BUFFER_S);
      // Waiting to try again: it will when switched back to. (A gap's slate
      // goes on waiting for its next program.)
      if (old?.retry !== undefined && old.state !== "gap") {
        window.clearTimeout(old.retry);
        old.retry = undefined;
        old.state = "failed";
      }
      // No longer a play: back on standby for Last — unless it's a
      // conversion, which isn't kept running off screen (nor tuned ahead),
      // and is tuned again if switched back to.
      if (old?.session && !old.standby) {
        if (old.session.method === "video_transcode") {
          old.ticket += 1;
          this.release(old);
          old.state = "unavailable";
        } else {
          old.standby = true;
          void api.post(`/playback_sessions/${old.session.id}/standby`, { position: old.element?.currentTime ?? old.session.resume_at }).catch(() => undefined);
        }
      }
    }
    const active = activeId ? this.slots.get(activeId) : null;
    active?.setBuffer?.(ON_SCREEN_BUFFER_S);
    if (active && previous !== activeId) {
      const ready = active.state === "ready" && Boolean(active.element?.readyState && active.element.readyState >= 2);
      this.switchedAt = { at: performance.now(), ready, stationId: active.stationId };
      if (active.state === "unavailable" || active.state === "gap" || active.state === "failed") {
        this.tune(active, { station_id: active.stationId });
      } else if (active.session) {
        if (active.standby) {
          active.standby = false;
          void api.post(`/playback_sessions/${active.session.id}/watch`, { position: this.liveAt(active) }).catch(() => undefined);
        }
        if (active.element && active.element.readyState >= 1) {
          seekWithin(active.element, this.liveAt(active));
          this.play(active);
        }
      }
    }
    this.rerender();
  }

  // Standby channels stay at live, and move on when their program ends. (A
  // gap's slate waits for its next program by itself: waitOutGap.)
  keepAtLive() {
    const timer = window.setInterval(() => {
      for (const slot of this.slots.values()) {
        if (this.isActive(slot)) continue;
        const element = slot.element;
        // A program's slot over (a game's too): on to what's on now.
        const live = slot.session?.live;
        if (live && Date.parse(live.ends_at) <= Date.now() + slot.skew) {
          this.tune(slot, { station_id: slot.stationId });
          continue;
        }
        // A stream: kept near its newest picture.
        if (slot.session?.live_stream) {
          if (element && slot.state === "ready" && element.seekable.length > 0 && !element.seeking) {
            const newest = element.seekable.end(element.seekable.length - 1);
            if (newest - element.currentTime > LIVE_SLACK_S) element.currentTime = Math.max(newest - 3, element.seekable.start(0));
          }
          continue;
        }
        if (element && slot.state === "ready" && element.readyState >= 1 && !element.seeking) {
          const target = keepLiveTarget(element.buffered, element.currentTime, Math.min(this.liveAt(slot), Math.max(element.duration - 0.5, 0)));
          if (Math.abs(target - element.currentTime) > LIVE_SLACK_S) element.currentTime = target;
        }
      }
    }, KEEP_LIVE_MS);
    return () => window.clearInterval(timer);
  }

  // Leaving for the guide, the picture on screen is lifted out before the
  // page's elements go: kept in the document, it never pauses, and the
  // preview takes the element itself (a layout cleanup runs before React
  // removes the page; the passive one, dispose, after). The guide is told
  // which channel was left here too: its own layout effect, which opens on
  // that channel, runs before any passive cleanup of this page's.
  parkForGuide() {
    const onScreen = this.activeId;
    if (!onScreen || liveHandoff.isSwapping(onScreen) || !this.toGuide?.()) return;
    liveHandoff.leave(onScreen);
    const slot = this.slots.get(onScreen);
    if (!slot?.element || !slot.session || slot.state !== "ready" || slot.session.method === "video_transcode" || !slot.source) return;
    this.parked = slot.element;
    liveHandoff.park(slot.element);
  }

  // Leaving the page lets every channel go — except, for the guide, the
  // one on screen: back on standby, it carries on in the guide's preview,
  // the same element still playing, as loud and as far behind live as it was.
  // (A conversion isn't kept on standby; the preview shows its still.)
  // Swapped into the inset (picture in picture), the one on screen is
  // handed there still playing, as far behind live as it was.
  dispose() {
    const onScreen = this.activeId;
    const toInset = onScreen !== null && liveHandoff.isSwapping(onScreen);
    const active = toInset || this.toGuide?.() ? onScreen : null;
    for (const slot of this.slots.values()) {
      slot.ticket += 1;
      window.clearTimeout(slot.retry);
      this.dropUpcoming(slot);
      const session = slot.session;
      if (toInset && slot.stationId === active && session && slot.state === "ready") {
        const element = slot.element;
        const behind = element && !session.live_stream ? Math.max(this.liveAt(slot) - element.currentTime, 0) : 0;
        slot.detach?.();
        slot.detach = null;
        slot.setBuffer = null;
        slot.session = null;
        liveHandoff.put(slot.stationId, session, slot.skew, behind);
      } else if (slot.stationId === active && session && slot.state === "ready" && session.method !== "video_transcode") {
        // (React has let go of its element by now: the parked one is it.)
        const element = this.parked ?? slot.element;
        const position = element?.currentTime ?? session.resume_at;
        // Parked: handed over with its source. The deck's own listener
        // stays on it, but with the slot gone it has nothing to act on.
        const picture = this.parked && slot.source ? { element: this.parked, detach: slot.source, playing: !this.parked.paused } : null;
        if (!picture) slot.detach?.();
        slot.detach = null;
        slot.source = null;
        slot.setBuffer = null;
        slot.session = null;
        if (!slot.standby) void api.post(`/playback_sessions/${session.id}/standby`, { position }).catch(() => undefined);
        liveHandoff.put(slot.stationId, session, slot.skew, 0, picture);
      } else this.release(slot);
    }
    this.slots.clear();
    // Parked but not handed over after all: nothing is left playing out of sight.
    if (this.parked && !liveHandoff.has(active ?? "")) this.parked.remove();
    this.parked = null;
  }

  // Time the change from the key to the first frame.
  timeSwitch(activeId: string | null) {
    const slot = activeId ? this.slots.get(activeId) : null;
    const element = slot?.element;
    const mark = this.switchedAt;
    if (!slot || !element || !mark || mark.stationId !== activeId) return undefined;
    // Asked after every render, not on a key: the slot's element may only just
    // have been bound. The first frame shown after the change ends it.
    return onFirstFrame(element, () => {
      const session = slot.session;
      if (!session || this.switchedAt !== mark) return;
      this.switchedAt = null;
      postEvents(session.events_url, [{ kind: "tune", position: element.currentTime, detail: { ms: Math.round(performance.now() - mark.at), ready: mark.ready } }]);
      element.dataset.tunedMs = String(Math.round(performance.now() - mark.at));
    });
  }

  // One ref callback per element, kept, so React doesn't detach and
  // re-attach the element on every render.
  readonly bind = (stationId: string, key: VideoKey = "a") => {
    const name = `${stationId}:${key}`;
    const known = this.binders.get(name);
    if (known) return known;
    const binder = (element: HTMLVideoElement | null) => {
      const slot = this.slots.get(stationId);
      if (!element) this.binders.delete(name);
      if (!slot || slot.videos[key] === element) return;
      slot.videos[key] = element;
      if (key !== slot.front) {
        if (element) this.attachUpcoming(slot);
        return;
      }
      slot.element = element;
      if (element) {
        element.muted = !this.isActive(slot) || viewerMuted();
        if (slot.session) this.attach(slot, this.isActive(slot) ? slot.session.resume_at : this.liveAt(slot));
      }
    };
    this.binders.set(name, binder);
    return binder;
  };

  private activeSlot() {
    return this.activeId ? this.slots.get(this.activeId) : null;
  }

  /** Play another airing on the channel on screen (this one from its start: Restart). */
  readonly retune = (body: TuneBody) => {
    const slot = this.activeSlot();
    if (!slot) return;
    slot.transition = null;
    this.tune(slot, body);
  };

  /** Tune the channel on screen again, from live: "Try again". */
  readonly retry = () => {
    const slot = this.activeSlot();
    if (!slot) return;
    slot.transition = null;
    this.tune(slot, { station_id: slot.stationId });
  };

  /**
   * The program on screen has ended: on to the next, `behind` live as far
   * as the viewer was — the one tuned ahead if there is one, else asked for
   * now. When the next is a while off, the slate until it starts.
   */
  readonly advance = (behind: number, via: EndedVia) => {
    const slot = this.activeSlot();
    if (!slot) return;
    const live = slot.session?.live;
    if (!live) {
      this.tune(slot, { station_id: slot.stationId });
      return;
    }
    slot.transition = { at: performance.now(), via, ready: Boolean(slot.upcoming) };
    const upcoming = slot.upcoming?.after === live.airing_id ? slot.upcoming : null;
    if (!upcoming) {
      this.tune(slot, { after_airing_id: live.airing_id, behind });
      return;
    }
    const startsIn = Date.parse(upcoming.session.live?.starts_at ?? "") - (Date.now() + upcoming.skew) - behind * 1000;
    if (startsIn <= FOLLOWING_EARLY_MS) {
      this.promote(slot, behind);
      return;
    }
    // A gap before it: the slate, the next program kept ready behind it.
    slot.ticket += 1;
    this.release(slot);
    this.waitOutGap(slot, startsIn, { after_airing_id: live.airing_id });
    this.rerender();
  };
}
