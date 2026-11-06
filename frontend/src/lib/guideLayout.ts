import type { Airing, Guide, GuideStation } from "@/types";

/**
 * The Grid guide's geometry and movement (PROPOSAL §7.7): time runs
 * across at a fixed number of pixels a minute, channels run down, and the
 * arrow keys move the way a TV guide's do — along a row program by
 * program, and between rows keeping to the same moment.
 */

export const MINUTE = 60_000;
export const HALF_HOUR = 30 * MINUTE;
/** The guide loads in slices this long, aligned to them. */
export const CHUNK = 3 * 60 * MINUTE;

export interface Geometry {
  /** The timeline's first moment (ms). */
  start: number;
  end: number;
  pxPerMinute: number;
}

export const xOf = (geometry: Geometry, time: number) => ((time - geometry.start) / MINUTE) * geometry.pxPerMinute;
export const timeOf = (geometry: Geometry, x: number) => geometry.start + (x / geometry.pxPerMinute) * MINUTE;

export const floorTo = (time: number, step: number) => Math.floor(time / step) * step;

/**
 * Where the guide opens on "now": the half hour before the current one, so
 * the programs on now show most of their cells rather than a sliver.
 */
export const openingTime = (now: number) => floorTo(now, HALF_HOUR) - HALF_HOUR;

/** Every half hour from start up to end. */
export function halfHours(start: number, end: number): number[] {
  const ticks: number[] = [];
  for (let tick = Math.ceil(start / HALF_HOUR) * HALF_HOUR; tick < end; tick += HALF_HOUR) ticks.push(tick);
  return ticks;
}

/** The aligned slices that cover [from, to). */
export function chunksCovering(from: number, to: number): number[] {
  const chunks: number[] = [];
  for (let chunk = floorTo(from, CHUNK); chunk < to; chunk += CHUNK) chunks.push(chunk);
  return chunks;
}

export interface GuideRow {
  station: GuideStation;
  airings: Airing[];
}

/** Slices of the guide as one: channels in the first slice's order, each row's airings once, by start. */
export function mergeGuides(guides: Guide[]): GuideRow[] {
  const first = guides[0];
  if (!first) return [];
  const byStation = new Map<string, Map<string, Airing>>();
  for (const guide of guides) {
    for (const station of guide.stations) {
      const row = byStation.get(station.id) ?? new Map<string, Airing>();
      for (const airing of station.airings) {
        // A stream's channel (PROPOSAL §7.8) is one program in every chunk
        // loaded: the chunks join into one span, rather than the last
        // loaded standing for all of them.
        const prior = row.get(airing.id);
        if (prior && airing.kind === "live_stream") {
          const starts = Math.min(Date.parse(prior.starts_at), Date.parse(airing.starts_at));
          const ends = Math.max(Date.parse(prior.ends_at), Date.parse(airing.ends_at));
          row.set(airing.id, { ...airing, starts_at: new Date(starts).toISOString(), ends_at: new Date(ends).toISOString() });
        } else row.set(airing.id, airing);
      }
      byStation.set(station.id, row);
    }
  }
  // Filler between programs isn't a program: the guide shows the gap. A
  // program broken for breaks is one program, first part to last.
  return first.stations.map((station) => ({
    station,
    airings: joinParts(
      [...(byStation.get(station.id)?.values() ?? [])]
        .filter((airing) => !airing.filler)
        .sort((a, b) => Date.parse(a.starts_at) - Date.parse(b.starts_at)),
    ),
  }));
}

/** A program's parts, from the first to the end of the last, as one. */
export function joinParts(airings: Airing[]): Airing[] {
  const joined: Airing[] = [];
  for (const airing of airings) {
    const last = joined.at(-1);
    if (last && airing.media_start > 0 && last.playable_id === airing.playable_id && (last.media_end ?? Infinity) <= airing.media_start + 0.5) {
      joined[joined.length - 1] = { ...last, ends_at: airing.ends_at, media_end: airing.media_end };
    } else joined.push(airing);
  }
  return joined;
}

/** What's on a row at a moment — or, in a gap, the nearest program after it, else before it. */
export function airingAt(airings: Airing[], time: number): Airing | null {
  const covering = airings.find((airing) => Date.parse(airing.starts_at) <= time && Date.parse(airing.ends_at) > time);
  if (covering) return covering;
  return airings.find((airing) => Date.parse(airing.starts_at) > time) ?? airings.at(-1) ?? null;
}

export interface Focus {
  row: number;
  airingId: string | null;
  /** The moment up and down keep to. */
  cursor: number;
}

export type Move = "left" | "right" | "up" | "down" | "pageUp" | "pageDown";

export const PAGE_ROWS = 7;

/**
 * Where a key moves the focus. Along a row: the program before or after,
 * never back past `earliest`. Between rows: whatever is on at the cursor.
 */
export function moveFocus(rows: GuideRow[], focus: Focus, move: Move, earliest: number): Focus {
  const current = rows[focus.row];
  if (!current) return focus;
  if (move === "left" || move === "right") {
    const index = current.airings.findIndex((airing) => airing.id === focus.airingId);
    const target = current.airings[index + (move === "right" ? 1 : -1)];
    if (index === -1 || !target || Date.parse(target.ends_at) <= earliest) return focus;
    return { row: focus.row, airingId: target.id, cursor: Math.max(Date.parse(target.starts_at), earliest) };
  }
  const step = move === "up" ? -1 : move === "down" ? 1 : move === "pageUp" ? -PAGE_ROWS : PAGE_ROWS;
  const row = Math.min(Math.max(focus.row + step, 0), rows.length - 1);
  if (row === focus.row) return focus;
  const target = airingAt(rows[row]?.airings ?? [], focus.cursor);
  return { row, airingId: target?.id ?? null, cursor: focus.cursor };
}
