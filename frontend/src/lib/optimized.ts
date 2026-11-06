import type { BadgeTone } from "@/components/ui/Badge";
import type { ConversionStatus, OptimizeAction, OptimizeActionResult, OptimizedReason, OptimizedState, OptimizerState } from "@/types";

export const OPTIMIZED_STATE_LABELS: Record<OptimizedState, string> = {
  queued: "Waiting",
  encoding: "Encoding",
  ready: "Ready",
  failed: "Failed",
  skipped: "Not optimizing",
};

export const OPTIMIZED_STATE_TONES: Record<OptimizedState, BadgeTone> = {
  queued: "neutral",
  encoding: "info",
  ready: "success",
  failed: "danger",
  skipped: "neutral",
};

/** Why it's queued, in a few words. */
export const OPTIMIZED_REASON_LABELS: Record<OptimizedReason, string> = {
  manual: "Asked for",
  all_devices: "No device plays it",
  airing: "Airs on the Grid",
  next_up: "Next episode",
};

/** "1 am" from 1, "midnight" from 0. */
export function formatHour(hour: number): string {
  if (hour === 0) return "midnight";
  if (hour === 12) return "noon";
  return hour < 12 ? `${hour} am` : `${hour - 12} pm`;
}

/** What an action did to the files it changed: "Queued 14". */
export const OPTIMIZE_ACTION_DONE: Record<OptimizeAction, string> = {
  optimize: "Queued",
  prioritize: "Moved to the front",
  skip: "Won't optimize",
  unskip: "Allowed again",
  reencode: "Making again",
  retry: "Retrying",
  delete: "Deleted",
};

/** A bulk action's outcome in one line: "Queued 14 · 3 already made · 1 can't be read yet". */
export function describeOptimizeResult(action: OptimizeAction, result: OptimizeActionResult): string {
  const parts = [result.changed > 0 ? `${OPTIMIZE_ACTION_DONE[action]} ${result.changed}` : "Nothing changed"];
  for (const [why, count] of Object.entries(result.unchanged)) parts.push(`${count} ${why}`);
  return parts.join(" · ");
}

/** The optimizer panel's headline per state. */
export const OPTIMIZER_STATE_LABELS: Record<OptimizerState, string> = {
  encoding: "Encoding",
  no_transcoder: "Transcoder not running",
  paused: "Paused",
  waiting_quiet_hours: "Waiting for quiet hours",
  over_budget: "Budget full",
  busy: "Giving way to a viewer",
  starting: "Starting",
  idle: "Idle",
};

export const OPTIMIZER_STATE_TONES: Record<OptimizerState, BadgeTone> = {
  encoding: "info",
  no_transcoder: "danger",
  paused: "warning",
  waiting_quiet_hours: "neutral",
  over_budget: "warning",
  busy: "neutral",
  starting: "info",
  idle: "neutral",
};

/** "18 min", "2 h 5 min" — how long an encode has left. */
export function formatDuration(seconds: number): string {
  if (seconds < 60) return "under a minute";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  return rest ? `${hours} h ${rest} min` : `${hours} h`;
}

/** A file's optimize status in the Needs converting table. */
export const CONVERSION_STATUS_LABELS: Record<ConversionStatus, string> = { none: "Not optimized", ...OPTIMIZED_STATE_LABELS };
export const CONVERSION_STATUS_TONES: Record<ConversionStatus, BadgeTone> = { none: "warning", ...OPTIMIZED_STATE_TONES };
