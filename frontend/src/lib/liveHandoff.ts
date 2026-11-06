import { releaseSession } from "@/lib/playbackSession";
import type { PlaybackSessionInfo } from "@/types";

/**
 * A channel already tuned elsewhere, handed over rather than tuned again
 * (PROPOSAL §7.7): the guide's preview window to the channel's own page
 * when someone chooses it, and that page back to the preview when they
 * leave it for the guide — so the picture carries on from a session the
 * server already has going. Taken once; let go after a minute if nobody
 * takes it. A swap with the inset (picture in picture) hands a channel or a
 * camera between its page and the inset the same way, still playing, and
 * as far behind live as it was.
 */
/**
 * The picture itself, handed over still playing: the channel's page leaving
 * for the guide gives the preview its element, source attached, so nothing
 * pauses, reloads or moves in time. `detach` lets its source go.
 */
export type HandedPicture = { element: HTMLVideoElement; detach: () => void; playing: boolean };

const pending = new Map<string, { session: PlaybackSessionInfo; skew: number; behind: number; picture: HandedPicture | null; expiry: number }>();
const FRESH_MS = 60_000;
/** A guide opened this soon after a channel was left opens on that channel. */
const RETURN_MS = 10_000;
let left: { stationId: string; at: number; volume: number } | null = null;
/** A swap under way: the picture under this key goes to the other place. */
let swap: { keys: string[]; at: number } | null = null;
const SWAP_MS = 2_000;
/** Takers waiting on a swap's handover: the page and the inset don't change in the same commit. */
const waiting = new Map<string, () => void>();

type Handed = { session: PlaybackSessionInfo; skew: number; behind: number; picture: HandedPicture | null };
/** How loud the channel's page has it: 0 when muted. */
let volume = 0;

const drop = (picture: HandedPicture | null) => {
  if (!picture) return;
  picture.detach();
  picture.element.remove();
};

/**
 * Where a handed-over picture waits between its page and the preview: in
 * the document (a media element taken out of it pauses), out of sight.
 */
let holder: HTMLDivElement | null = null;

export const liveHandoff = {
  /** Keyed by station id, or `stream:<id>` for a camera or web stream (pip handoffKey). */
  put(stationId: string, session: PlaybackSessionInfo, skew: number, behind = 0, picture: HandedPicture | null = null) {
    const before = pending.get(stationId);
    if (before) {
      window.clearTimeout(before.expiry);
      if (before.session.id !== session.id) releaseSession(before.session);
      if (before.picture?.element !== picture?.element) drop(before.picture);
    }
    const expiry = window.setTimeout(() => {
      pending.delete(stationId);
      drop(picture);
      releaseSession(session);
    }, FRESH_MS);
    pending.set(stationId, { session, skew, behind, picture, expiry });
    const waiter = waiting.get(stationId);
    waiting.delete(stationId);
    waiter?.();
  },
  has(stationId: string): boolean {
    return pending.has(stationId);
  },
  /** Its session — and, for a taker that can show it (`picture`), the element still playing; otherwise that's let go. */
  take(stationId: string, { picture: wanted = false }: { picture?: boolean } = {}): Handed | null {
    const entry = pending.get(stationId);
    if (!entry) return null;
    pending.delete(stationId);
    window.clearTimeout(entry.expiry);
    const picture = wanted ? entry.picture : null;
    if (!wanted) drop(entry.picture);
    // A program that has ended since is no use; a stream never ends.
    const live = entry.session.live;
    if (!live || Date.parse(live.ends_at) > Date.now() + entry.skew) return { session: entry.session, skew: entry.skew, behind: entry.behind, picture };
    drop(picture);
    releaseSession(entry.session);
    return null;
  },
  /**
   * Keep a playing element in the document, out of sight, while its page
   * goes and the preview comes — silent, so a picture nobody takes is never
   * heard (the preview sets its sound as it moves it in).
   */
  park(element: HTMLVideoElement) {
    element.muted = true;
    if (!holder || !holder.isConnected) {
      holder = document.createElement("div");
      holder.setAttribute("aria-hidden", "true");
      holder.style.cssText = "position:fixed;left:0;top:0;width:1px;height:1px;overflow:hidden;opacity:0;pointer-events:none";
      document.body.append(holder);
    }
    holder.append(element);
  },
  /**
   * Take what's handed over — and, in a swap, wait for it: the route
   * changes as a transition, so the page can hand its picture over a
   * moment after the inset has come to take it (or the other way round).
   */
  receive(stationId: string): Promise<Handed | null> {
    const now = liveHandoff.take(stationId);
    if (now || !liveHandoff.isSwapping(stationId)) return Promise.resolve(now);
    return new Promise((resolve) => {
      const timer = window.setTimeout(() => {
        waiting.delete(stationId);
        resolve(null);
      }, SWAP_MS);
      waiting.set(stationId, () => {
        window.clearTimeout(timer);
        resolve(liveHandoff.take(stationId));
      });
    });
  },
  /** The pictures under these keys are trading places: each is handed over rather than let go. */
  swapping(...keys: string[]) {
    swap = { keys, at: Date.now() };
  },
  /** Whether the picture under this key (or, without one, any) is being swapped just now. */
  isSwapping(key?: string): boolean {
    if (!swap || Date.now() - swap.at > SWAP_MS) return false;
    return key === undefined || swap.keys.includes(key);
  },
  /** The channel's page, saying how loud it is (0 when muted). */
  heard(level: number) {
    volume = level;
  },
  /** This channel's page was just left for the guide. */
  leave(stationId: string) {
    left = { stationId, at: Date.now(), volume };
    volume = 0;
  },
  /** The channel just left for the guide, for the guide to open on. */
  leftFrom(): string | null {
    return left && Date.now() - left.at < RETURN_MS ? left.stationId : null;
  },
  /** How loud it was when it was left: 0 when it was muted, or wasn't just left. */
  leftVolume(): number {
    return left && Date.now() - left.at < RETURN_MS ? left.volume : 0;
  },
};
