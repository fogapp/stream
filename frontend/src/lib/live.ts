import type { Airing, GuideStation, StationFiller, StationLayer, StationOrdering } from "@/types";

/** Grid (PROPOSAL §7.7): display maps and the arithmetic of "live". */

export const LAYER_LABELS: Record<StationLayer, string> = {
  base: "The mix",
  daypart: "Daypart",
  appointment: "Appointment",
  special: "Special",
};

export const LAYER_HINTS: Record<StationLayer, string> = {
  base: "What airs whenever nothing else is scheduled.",
  daypart: "A stretch of the day on chosen days — mornings, primetime, late night. Starts once what's on finishes.",
  appointment: "A fixed slot, like Sunday at 8pm. Starts on the dot; what airs before it ends in time.",
  special: "Takes over between two dates — a holiday marathon. Starts on the dot.",
};

export const ORDERING_LABELS: Record<StationOrdering, string> = {
  shuffle: "Shuffled",
  sequential: "In order",
  rotate: "Rotating shows",
  marathon: "Marathons",
  chronological: "As they first aired",
};

export const ORDERING_HINTS: Record<StationOrdering, string> = {
  shuffle: "Anything that matches, not repeated for a few days.",
  sequential: "Straight through, S1E1 onwards, picking up where it left off.",
  rotate: "Each show in turn, each where it left off — like syndication.",
  marathon: "A few episodes of one show in a row, then another show.",
  chronological: "Everything by original air date, across shows.",
};

export const SNAP_OPTIONS = [
  { value: 0, label: "Back to back" },
  { value: 5, label: "Every 5 minutes" },
  { value: 15, label: "Quarter hours" },
  { value: 30, label: "Half hours" },
  { value: 60, label: "On the hour" },
] as const;

/** Milliseconds to add to this device's clock to get the server's. */
export function clockSkew(serverNow: string, receivedAt = Date.now()): number {
  const server = Date.parse(serverNow);
  return Number.isFinite(server) ? server - receivedAt : 0;
}

/** Where live is in an airing, in seconds into it. */
export function liveOffset(airing: { starts_at: string; ends_at: string }, now: number): number {
  const start = Date.parse(airing.starts_at);
  const length = (Date.parse(airing.ends_at) - start) / 1000;
  return Math.min(Math.max((now - start) / 1000, 0), Math.max(length, 0));
}

/**
 * Where a standby channel is moved to keep it at live: live itself while
 * that's inside what it has buffered (or nothing is, yet) — otherwise the
 * end of what it has, so its buffer grows on from there in order. A nudge
 * past the buffer is a seek: the transcoder started again at live, and
 * again at whatever lay between when the buffer went back to fill it.
 */
export function keepLiveTarget(buffered: TimeRanges, current: number, live: number): number {
  for (let i = 0; i < buffered.length; i += 1) {
    if (buffered.start(i) <= live && live <= buffered.end(i)) return live;
  }
  for (let i = 0; i < buffered.length; i += 1) {
    if (buffered.start(i) <= current && current <= buffered.end(i)) return Math.min(live, Math.max(buffered.end(i) - 0.5, current));
  }
  return live;
}

/** Near enough a program's end that a picture stuck there is the end, not a stall (a GOP or a segment of slack). */
const NEAR_END_S = 12;
/** How long a picture can stay put near the end before the program counts as over. */
const STUCK_MS = 6_000;

/**
 * Whether a program has played out even though its stream never said so
 * (no `ended`: a last segment that never came, a browser that paused at
 * the end). Seconds into the file; `stuckMs` is how long playing has
 * stayed at `position` without being paused or seeking.
 */
export function stuckAtEnd({ position, end, stuckMs, paused }: { position: number; end: number; stuckMs: number; paused: boolean }): boolean {
  if (!Number.isFinite(end)) return false;
  const left = end - position;
  if (paused) return left < 0.3;
  return left < NEAR_END_S && stuckMs >= STUCK_MS;
}

/** The longest a slate waits before asking again: the schedule may have changed meanwhile. */
const GAP_WAIT_MAX_MS = 5 * 60_000;
/** Asked again this often when nothing is scheduled at all. */
const GAP_POLL_MS = 60_000;

/**
 * A 409 from tuning: a gap in the schedule (the slate, until the server's
 * Retry-After — the next program's start), or something else.
 */
export function gapWait(message: string, retryAfter: number | null): number | null {
  if (!/right now|hasn't started/.test(message)) return null;
  return retryAfter === null ? GAP_POLL_MS : Math.min(retryAfter * 1000, GAP_WAIT_MAX_MS);
}

/** What's on a channel at a moment, and what's next after it. */
export function onAt(station: GuideStation, now: number): { current: Airing | null; next: Airing | null } {
  const current = station.airings.find((airing) => Date.parse(airing.starts_at) <= now && Date.parse(airing.ends_at) > now) ?? null;
  const next = station.airings.find((airing) => Date.parse(airing.starts_at) > now) ?? null;
  return { current, next };
}

/** "8:30", "8:30 PM" — the household's clock, in its own zone. */
export function clockTime(iso: string, timeZone: string, withPeriod = true): string {
  const text = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit", timeZone }).format(new Date(iso));
  return withPeriod ? text : text.replace(/\s?[AP]M$/i, "");
}

/** The channel after (step 1) or before (-1) this one, wrapping around. */
export function adjacentStation<T extends { number: string }>(stations: T[], number: string, step: 1 | -1): T | null {
  if (stations.length === 0) return null;
  const index = stations.findIndex((station) => station.number === number);
  if (index === -1) return stations[0] ?? null;
  return stations[(index + step + stations.length) % stations.length] ?? null;
}

/** Days as bits, Monday first — the backend's StationBlock#days. */
export const WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] as const;

/** "20:00" ↔ minutes after midnight, for time inputs. */
export function minutesToTime(minutes: number | null): string {
  if (minutes === null) return "";
  const clamped = Math.min(Math.max(minutes, 0), 1440) % 1440;
  return `${String(Math.floor(clamped / 60)).padStart(2, "0")}:${String(clamped % 60).padStart(2, "0")}`;
}

export function timeToMinutes(text: string): number | null {
  const match = /^(\d{1,2}):(\d{2})$/.exec(text);
  if (!match) return null;
  const minutes = Number(match[1]) * 60 + Number(match[2]);
  return minutes >= 0 && minutes <= 1440 ? minutes : null;
}

/** Midnight at the start of this moment's day, on the household's clock. */
export function dayStart(time: number, timeZone: string): number {
  const parts = new Intl.DateTimeFormat("en-GB", { timeZone, hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" })
    .formatToParts(new Date(time))
    .reduce<Record<string, number>>((all, part) => (part.type === "literal" ? all : { ...all, [part.type]: Number(part.value) }), {});
  const since = ((parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)) * 1000 + (time % 1000);
  return time - since;
}

/** Each layer's colour on the schedule editor's clock and preview (tokens only). */
export const LAYER_TONES: Record<StationLayer, string> = {
  base: "border-border bg-surface-raised",
  daypart: "border-primary/50 bg-primary/20",
  appointment: "border-positive/50 bg-positive/25",
  special: "border-warning/50 bg-warning/25",
};

export const FILLER_LABELS: Record<StationFiller, string> = {
  slate: "What's next, and a countdown",
  extras: "The library's trailers and featurettes",
  videos: "Videos from YouTube channels",
};

/** "Monday 8pm–9pm" for a block, from its own fields. */
export function dayMask(days: number, index: number): boolean {
  return (days & (1 << index)) !== 0;
}
