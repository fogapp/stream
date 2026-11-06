import { api, ApiError } from "@/api/client";
import { adaptiveQuality, capabilityProfile, deviceKey } from "@/lib/capabilities";
import type { PlayableKind, PlaybackSessionInfo } from "@/types";

/**
 * Asks for a play. Every one carries what this browser can decode, which
 * device it is, and whether it wants smaller versions to drop to — a
 * preview handed to its page plays on as the page would have asked.
 */
export function createSession(body: Record<string, unknown>) {
  return api.post<PlaybackSessionInfo>("/playback_sessions", {
    ...body,
    capabilities: capabilityProfile(),
    device_key: deviceKey(),
    abr: adaptiveQuality() || undefined,
  });
}

/** Ends a play; one that can't be told is ended by the server once it goes quiet. */
export function releaseSession(session: Pick<PlaybackSessionInfo, "id">) {
  void api.delete(`/playback_sessions/${session.id}`).catch(() => undefined);
}

/**
 * Not playable yet (its keyframe index is being built): how long until the
 * server says to ask again, in ms. Null when that isn't what this failure is.
 */
export function readyInMs(failure: unknown): number | null {
  return failure instanceof ApiError && failure.status === 409 && failure.retryAfter !== null ? failure.retryAfter * 1000 : null;
}

export interface PlaybackEventReport {
  kind: string;
  position: number;
  detail?: Record<string, string | number | boolean>;
}

export interface ProgressReport {
  position: number;
  ended: boolean;
}

const post = (url: string, body: unknown) =>
  fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body), keepalive: true });

/** What a play went through, for the Playback decisions page. Keepalive, so it outlives the page; a miss is only a lost note. */
export function postEvents(url: string, events: PlaybackEventReport[]) {
  void post(url, { events }).catch(() => undefined);
}

/** Where the viewer is, which keeps the session open. The server's answer, or null when there wasn't one. */
export function postProgress<T>(url: string, body: ProgressReport): Promise<T | null> {
  return post(url, body)
    .then((response) => (response.ok ? (response.json() as Promise<T>) : null))
    .catch(() => null);
}

/**
 * The last report as the page goes: a beacon survives that, a fetch might
 * not. False where there's no beacon, so the caller can post instead.
 */
export function beaconProgress(url: string, body: ProgressReport): boolean {
  if (!navigator.sendBeacon) return false;
  navigator.sendBeacon(url, new Blob([JSON.stringify(body)], { type: "text/plain" }));
  return true;
}

/**
 * Whether a title can still be played: false when it's been purged (not
 * found) or every file it had is gone. A failure to ask says nothing, so
 * it's null rather than false.
 */
export async function stillPlayable(kind: PlayableKind, id: string): Promise<boolean | null> {
  const query = new URLSearchParams({ playable_type: kind, playable_id: id });
  try {
    const { readable } = await api.get<{ readable: boolean }>(`/playback_sessions/readable?${query}`);
    return readable;
  } catch (failure) {
    return failure instanceof ApiError && failure.status === 404 ? false : null;
  }
}
