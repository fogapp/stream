import type { PlayableKind, PlaybackSessionInfo } from "@/types";

/**
 * A playback session asked for ahead of time (PROPOSAL §7.3: the next
 * episode during the credits), so the transcoder is already warming it when
 * the player gets there. Taken once; stale after a few minutes.
 */
const pending = new Map<string, { at: number; session: Promise<PlaybackSessionInfo> }>();
const FRESH_MS = 5 * 60_000;

export const prefetchedSessions = {
  put(key: string, session: Promise<PlaybackSessionInfo>) {
    session.catch(() => pending.delete(key));
    pending.set(key, { at: Date.now(), session });
  },
  has(key: string): boolean {
    const entry = pending.get(key);
    return Boolean(entry && Date.now() - entry.at < FRESH_MS);
  },
  take(key: string): Promise<PlaybackSessionInfo> | null {
    const entry = pending.get(key);
    pending.delete(key);
    return entry && Date.now() - entry.at < FRESH_MS ? entry.session : null;
  },
};

const PLAYABLE_KINDS = new Set<PlayableKind>(["movie", "episode", "extra", "video", "clip"]);

/**
 * The title a press would play: a link or button to /watch/… (a button
 * says where with data-watch). Only a plain start, perhaps from the top or
 * in a playlist: a particular version or a timestamp asks for its own
 * session when it gets there.
 */
export function pressedTitle(target: EventTarget | null): { kind: PlayableKind; id: string; playlistId: string | null } | null {
  const element = target instanceof Element ? target.closest("[data-watch], a[href]") : null;
  const href = element?.getAttribute("data-watch") ?? element?.getAttribute("href");
  const match = href ? /^\/watch\/([a-z]+)\/([^/?#]+)(?:\?([^#]*))?$/.exec(href) : null;
  if (!match) return null;
  const kind = match[1] as PlayableKind;
  if (!PLAYABLE_KINDS.has(kind)) return null;
  const query = new URLSearchParams(match[3] ?? "");
  if ([...query.keys()].some((key) => key !== "playlist" && key !== "from")) return null;
  return { kind, id: decodeURIComponent(match[2]!), playlistId: query.get("playlist") };
}
