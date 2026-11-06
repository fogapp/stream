import type { BadgeTone } from "@/components/ui/Badge";
import type { NtfyPush } from "@/types";

/**
 * What each notification kind is about, for the badge beside the title.
 * `kind` is a free string on the wire — Notifier callers coin them — so an
 * unknown kind falls back to its own name rather than crashing the page.
 * Kinds land here as the features that send them do.
 */
const KIND_LABELS: Record<string, string> = {
  scan_finished: "Scan",
  library_unreachable: "Library unreachable",
  live_reminder: "Grid",
};

const KIND_TONES: Record<string, BadgeTone> = {
  scan_finished: "info",
  library_unreachable: "danger",
  live_reminder: "info",
};

export function notificationKindLabel(kind: string): string {
  return KIND_LABELS[kind] ?? kind.replaceAll("_", " ");
}

export function notificationKindTone(kind: string): BadgeTone {
  return KIND_TONES[kind] ?? "neutral";
}

/** What lands on a profile's ntfy topic, for the list of topics to subscribe to. */
export const NTFY_PUSH_LABELS: Record<NtfyPush, string> = {
  new_episodes: "new episodes",
  new_videos: "new videos from subscriptions",
  live_reminders: "Grid reminders",
};
