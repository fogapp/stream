/** 1h 52m, or 47m. */
export function formatRuntime(minutes: number | null | undefined): string | null {
  if (!minutes) return null;
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  return hours > 0 ? `${hours}h ${rest}m` : `${rest}m`;
}

/** A playback clock: 1:02:03, or 4:05 under an hour. */
/** "31 Jan 2024", for a calendar date ("2024-01-31") read in local time. */
export function formatDay(value: string | null | undefined): string | null {
  if (!value) return null;
  const date = new Date(`${value.slice(0, 10)}T00:00:00`);
  return Number.isNaN(date.getTime()) ? null : date.toLocaleDateString(undefined, { dateStyle: "medium" });
}

export function formatClock(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (value: number) => value.toString().padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
}

/**
 * When a clip was taken, formatted: a floating time is the camera's wall
 * clock stored as UTC, so it's shown in UTC and never shifted; an instant
 * is shown in the viewer's zone.
 */
export function formatCaptured(clip: { captured_at: string; captured_floating: boolean }, options: Intl.DateTimeFormatOptions): string {
  return new Date(clip.captured_at).toLocaleString(undefined, { ...options, timeZone: clip.captured_floating ? "UTC" : undefined });
}

/** The year and month (0-11) a clip belongs under, by the same rule. */
export function capturedMonth(clip: { captured_at: string; captured_floating: boolean }): { year: number; month: number } {
  const date = new Date(clip.captured_at);
  return clip.captured_floating ? { year: date.getUTCFullYear(), month: date.getUTCMonth() } : { year: date.getFullYear(), month: date.getMonth() };
}

/** "1 play", "3 plays"; `plural` where adding an s won't do. */
export function plural(count: number, noun: string, many = `${noun}s`): string {
  return `${count} ${count === 1 ? noun : many}`;
}
