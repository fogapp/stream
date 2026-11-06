import type { MouseEvent } from "react";
import type { PlayableKind } from "@/types";

/**
 * A second picture over the one playing (picture in picture): a title, a
 * Grid channel, or a camera or web stream — over any of those. Swapping
 * trades the two places; the sound is the main picture's, the inset's, or
 * both.
 */
export type PipSource =
  | { kind: "title"; playable: PlayableKind; id: string; title: string }
  | { kind: "station"; stationId: string; number: string; title: string }
  | { kind: "stream"; id: string; title: string };

/** Whose sound plays. */
export const PIP_AUDIO = ["main", "both", "pip"] as const;
export type PipAudio = (typeof PIP_AUDIO)[number];

export const PIP_AUDIO_OPTIONS: Record<PipAudio, { label: string; title: string }> = {
  main: { label: "Main", title: "Sound from the main picture" },
  both: { label: "Both", title: "Sound from both pictures" },
  pip: { label: "Inset", title: "Sound from this picture" },
};

/** Whether a picture in this place is heard. */
export function hears(audio: PipAudio, place: "main" | "pip"): boolean {
  return audio === "both" || audio === place;
}

/** The choice after unmuting a picture that the choice had silenced: both, then. */
export function heardToo(audio: PipAudio, place: "main" | "pip"): PipAudio {
  return hears(audio, place) ? audio : "both";
}

/** Whether two sources are the same thing playing. */
export function sameSource(a: PipSource | null, b: PipSource | null): boolean {
  if (!a || !b || a.kind !== b.kind) return false;
  if (a.kind === "title" && b.kind === "title") return a.playable === b.playable && a.id === b.id;
  if (a.kind === "station" && b.kind === "station") return a.stationId === b.stationId;
  return a.kind === "stream" && b.kind === "stream" && a.id === b.id;
}

/** Where a live source is handed over between its page and the inset (liveHandoff). */
export function handoffKey(source: Extract<PipSource, { kind: "station" | "stream" }>): string {
  return source.kind === "station" ? source.stationId : `stream:${source.id}`;
}

/** A live source's own full-screen page. */
export function livePath(source: Extract<PipSource, { kind: "station" | "stream" }>): string {
  return source.kind === "station" ? `/live/${encodeURIComponent(source.number)}` : `/stream/${source.id}`;
}

/**
 * Into or out of browser full screen on `target`: a player's own frame, or
 * the whole page when an inset must show too — the browser shows only
 * what's inside the full-screen element.
 */
export function toggleFullscreen(target: HTMLElement | null) {
  if (document.fullscreenElement) void document.exitFullscreen().catch(() => undefined);
  else void target?.requestFullscreen().catch(() => undefined);
}

/** A double click on the inset's picture swaps it — not one on its buttons, pressed twice. */
export function swapOnDoubleClick(event: MouseEvent, onSwap: (() => void) | undefined) {
  if (event.target instanceof Element && event.target.closest("button, a, [role=radiogroup]")) return;
  onSwap?.();
}
