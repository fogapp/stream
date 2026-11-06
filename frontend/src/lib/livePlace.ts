/**
 * Where a viewer was on a Grid channel when they'd gone back in its
 * program (PROPOSAL §7.7, behind live like a DVR), kept for a reload of the
 * page: a channel tunes to live, and without this a refresh — or a deploy
 * mid-program — put them back at live with the place to find again.
 *
 * In sessionStorage, so it's this tab's and goes with it. Only for the
 * channel on screen, only while they're behind live, and forgotten when
 * they change channel or leave: a reload is the one way back to the page
 * that doesn't go through either.
 */
const KEY = "stream_live_place";

export interface LivePlace {
  stationId: string;
  airingId: string;
  /** Seconds into the file. */
  position: number;
  /** When the airing ends: after that there's nothing to come back to. */
  endsAt: string;
}

/** The channel on screen; null when the Grid page isn't. */
let watching: string | null = null;

function stored(): LivePlace | null {
  try {
    const parsed = JSON.parse(sessionStorage.getItem(KEY) ?? "null") as Partial<LivePlace> | null;
    if (!parsed || typeof parsed.stationId !== "string" || typeof parsed.airingId !== "string") return null;
    if (typeof parsed.position !== "number" || typeof parsed.endsAt !== "string") return null;
    return parsed as LivePlace;
  } catch {
    return null;
  }
}

function forget() {
  try {
    sessionStorage.removeItem(KEY);
  } catch {
    // A nicety.
  }
}

export const livePlace = {
  /** This channel is on screen now: a place kept for another is let go. */
  watch(stationId: string) {
    watching = stationId;
    if (stored()?.stationId !== stationId) forget();
  },
  /** The Grid page was left. */
  leave() {
    watching = null;
    forget();
  },
  /** Behind live on the channel on screen: remembered. A report from a channel just changed away from isn't. */
  save(place: LivePlace) {
    if (place.stationId !== watching) return;
    try {
      sessionStorage.setItem(KEY, JSON.stringify(place));
    } catch {
      // A nicety.
    }
  },
  /** At live again on this channel: nothing to come back to. */
  clear(stationId: string) {
    if (stored()?.stationId === stationId) forget();
  },
  /** What to tune this channel with after a reload: the airing they were in and where, while it's still on. */
  resume(stationId: string, now: number): { airing_id: string; start: number } | null {
    const place = stored();
    if (!place || place.stationId !== stationId || !(Date.parse(place.endsAt) > now)) return null;
    return { airing_id: place.airingId, start: place.position };
  },
};
