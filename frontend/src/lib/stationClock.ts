import { dayMask } from "@/lib/live";
import type { StationBlock } from "@/types";

export interface Segment {
  index: number;
  day: number;
  start: number;
  end: number;
  /** The second half of a block that runs past midnight. */
  continued: boolean;
}

/** Where a block sits on a week's clock: a band per day it's on, split at midnight. */
export function segmentsOf(block: StationBlock, index: number, weekStart: Date): Segment[] {
  if (block.layer === "base" || block.start_minute === null || block.end_minute === null) return [];
  const segments: Segment[] = [];
  for (let day = 0; day < 7; day += 1) {
    if (!dayMask(block.days, day)) continue;
    if (block.layer === "special") {
      const date = new Date(weekStart.getTime() + day * 86_400_000).toISOString().slice(0, 10);
      if ((block.starts_on && date < block.starts_on) || (block.ends_on && date > block.ends_on)) continue;
    }
    const { start_minute: start, end_minute: end } = block;
    if (start < end) segments.push({ index, day, start, end, continued: false });
    else {
      segments.push({ index, day, start, end: 1440, continued: false });
      if (end > 0) segments.push({ index, day: (day + 1) % 7, start: 0, end, continued: true });
    }
  }
  return segments;
}

