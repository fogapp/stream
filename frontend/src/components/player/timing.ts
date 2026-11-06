import { useEffect, useRef, useState } from "react";
import { isResyncSeek } from "@/components/player/audio";

/**
 * How long playing took to start and seeks took to land
 * (docs/PERF_PROPOSAL.md › P1), measured in the browser, where the viewer
 * feels it, and reported as `startup` and `seek` events for the Playback
 * decisions page.
 */

/** A press of Play, as the player learns of it: when the session was asked for and when it answered. */
export interface StartMark {
  requestedAt: number;
  answeredAt: number;
}

export type Milestone = "manifest" | "init" | "fragment";

/**
 * A run of seeks from keys or buttons lands this long after the last
 * (docs/PERF_PROPOSAL.md › P14): each press moves the bar at once, and the
 * element goes to the last of a quick run of them, so holding a key asks
 * the transcoder for one place, not thirty.
 */
export const SEEK_SETTLE_MS = 150;

export interface Startup {
  /** Press to first frame. */
  ms: number;
  /** Each step, counted from the press: absent when this path has no such step (a file, native HLS). */
  session_ms: number;
  manifest_ms?: number;
  init_ms?: number;
  fragment_ms?: number;
  frame_ms: number;
}

export interface Seek {
  ms: number;
  /** Landed inside what was already buffered. */
  ready: boolean;
}

/** Sessions asked for, and when: a session asked for ahead (a click, Up next) starts its clock then. */
const requested = new WeakMap<Promise<unknown>, number>();

/** When a session was asked for: now, or when an earlier ask for it was (asked again after Retry-After). */
export function markRequested<T>(session: Promise<T>, at: number = performance.now()): Promise<T> {
  requested.set(session, at);
  return session;
}

export function requestedAt(session: Promise<unknown>): number | null {
  return requested.get(session) ?? null;
}

/** The startup report from the milestones seen, each relative to the press. */
export function startupDetail(mark: StartMark, milestones: Partial<Record<Milestone, number>>, frameAt: number): Startup {
  const since = (at: number) => Math.max(0, Math.round(at - mark.requestedAt));
  const detail: Startup = { ms: since(frameAt), session_ms: since(mark.answeredAt), frame_ms: since(frameAt) };
  if (milestones.manifest !== undefined) detail.manifest_ms = since(milestones.manifest);
  if (milestones.init !== undefined) detail.init_ms = since(milestones.init);
  if (milestones.fragment !== undefined) detail.fragment_ms = since(milestones.fragment);
  return detail;
}

/** "640 ms: session 90, playlist 120, init 300, first fragment 520" — each step counted from the press. */
export function startupLabel(startup: Startup): string {
  const steps = [
    ["session", startup.session_ms],
    ["playlist", startup.manifest_ms],
    ["init", startup.init_ms],
    ["first fragment", startup.fragment_ms],
  ] as const;
  const parts = steps.filter(([, ms]) => ms !== undefined).map(([label, ms]) => `${label} ${ms}`);
  return `${startup.ms} ms: ${parts.join(", ")}`;
}

/** Whether a position is inside what the element has buffered. */
export function isBuffered(ranges: TimeRanges, at: number): boolean {
  for (let i = 0; i < ranges.length; i += 1) {
    if (ranges.start(i) <= at && at <= ranges.end(i)) return true;
  }
  return false;
}

/** Buffered ranges closer together than this are one piece with a hole, which is hls.js's to hop. */
const ISLAND_GAP_S = 0.25;

/**
 * Where what's buffered stops being one piece with a position: the end of
 * the range it's in, or the position itself when it's in none — if
 * anything is buffered past there. null when nothing is.
 *
 * What's past there is an island a seek left behind. Filling the buffer up
 * to one means appending the GOP before it after it's already there, and
 * Chrome's MediaSource then throws away the island's first GOP of picture
 * if the appended GOP's last frame runs past the island's keyframe — by a
 * millisecond, which Matroska's rounded timestamps manage at many
 * keyframes. It still reports the range whole, so nothing reloads it: the
 * sound plays on over a frozen picture until the next keyframe. So islands
 * ahead are let go of before the buffer reaches them (source.ts).
 */
export function islandsFrom(ranges: TimeRanges, at: number): number | null {
  let from = at;
  for (let i = 0; i < ranges.length; i += 1) {
    if (ranges.start(i) <= at && at <= ranges.end(i)) from = ranges.end(i);
  }
  for (let i = 0; i < ranges.length; i += 1) {
    if (ranges.start(i) > from + ISLAND_GAP_S) return from;
  }
  return null;
}

/** Calls back on the first frame shown: the browser's own frame callback where it has one, else "playing". Returns its cancel. */
export function onFirstFrame(element: HTMLVideoElement, callback: () => void): () => void {
  let done = false;
  const once = () => {
    if (done) return;
    done = true;
    callback();
  };
  element.addEventListener("playing", once, { once: true });
  const frame = "requestVideoFrameCallback" in element ? element.requestVideoFrameCallback(once) : null;
  return () => {
    done = true;
    element.removeEventListener("playing", once);
    if (frame !== null) element.cancelVideoFrameCallback(frame);
  };
}

/**
 * Times this session's start and every seek after it. `milestone` is handed
 * to the source so hls.js can say when its steps landed; `report` sends an
 * event. The last of each is kept for the stats overlay, and on the element
 * (`data-startup-ms`, `data-seek-ms`) for the browser harness. `playing`
 * is for an element handed over with its picture already going (a Grid
 * channel, whose start is timed as a tune): only its seeks are timed.
 */
export function usePlaybackTiming(
  element: HTMLVideoElement | null,
  mark: StartMark | null,
  report: (kind: "startup" | "seek", position: number, detail: Startup | Seek) => void,
  playing = false,
) {
  const milestones = useRef<Partial<Record<Milestone, number>>>({});
  const [startup, setStartup] = useState<Startup | null>(null);
  const [lastSeek, setLastSeek] = useState<Seek | null>(null);
  const started = useRef(playing);
  const reportRef = useRef(report);
  reportRef.current = report;

  const milestone = useRef((name: Milestone) => {
    milestones.current[name] ??= performance.now();
  }).current;

  useEffect(() => {
    if (!element || !mark || started.current) return;
    return onFirstFrame(element, () => {
      started.current = true;
      const detail = startupDetail(mark, milestones.current, performance.now());
      element.dataset.startupMs = String(detail.ms);
      setStartup(detail);
      reportRef.current("startup", element.currentTime, detail);
    });
  }, [element, mark]);

  // Seeks after the start: from the seek to the frame at the new place.
  useEffect(() => {
    if (!element) return;
    let seeking: { at: number; ready: boolean } | null = null;
    const onSeeking = () => {
      // A resync's seek (audio.ts) is the player's, not the viewer's.
      if (!started.current || isResyncSeek(element)) return;
      seeking = { at: performance.now(), ready: isBuffered(element.buffered, element.currentTime) };
    };
    const onSeeked = () => {
      const began = seeking;
      seeking = null;
      if (!began) return;
      const detail: Seek = { ms: Math.round(performance.now() - began.at), ready: began.ready };
      element.dataset.seekMs = String(detail.ms);
      setLastSeek(detail);
      reportRef.current("seek", element.currentTime, detail);
    };
    element.addEventListener("seeking", onSeeking);
    element.addEventListener("seeked", onSeeked);
    return () => {
      element.removeEventListener("seeking", onSeeking);
      element.removeEventListener("seeked", onSeeked);
    };
  }, [element]);

  return { milestone, startup, lastSeek };
}
