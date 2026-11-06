import type { PlayableKind } from "@/types";

/**
 * What this browser was last watching, per profile, so a reload (or coming
 * back tomorrow) offers it again in the corner. Where to resume is the
 * server's (resume_at); position and the still here are only for showing.
 */
export interface LastWatched {
  kind: PlayableKind;
  id: string;
  title: string;
  subtitle: string | null;
  playlistId: string | null;
  mediaFileId: string | null;
  position: number;
  duration: number;
  /** A small JPEG of the frame it was left on, when the browser let us take one. */
  still: string | null;
}

const PREFIX = "stream_last_watched:";
const KINDS: readonly PlayableKind[] = ["movie", "episode", "extra", "video", "clip"];

function key(profileId: string | null) {
  return `${PREFIX}${profileId ?? "default"}`;
}

export function loadLastWatched(profileId: string | null): LastWatched | null {
  try {
    const parsed = JSON.parse(localStorage.getItem(key(profileId)) ?? "null") as Partial<LastWatched> | null;
    if (!parsed || typeof parsed.id !== "string" || typeof parsed.title !== "string") return null;
    if (!KINDS.includes(parsed.kind as PlayableKind)) return null;
    return {
      kind: parsed.kind as PlayableKind,
      id: parsed.id,
      title: parsed.title,
      subtitle: typeof parsed.subtitle === "string" ? parsed.subtitle : null,
      playlistId: typeof parsed.playlistId === "string" ? parsed.playlistId : null,
      mediaFileId: typeof parsed.mediaFileId === "string" ? parsed.mediaFileId : null,
      position: Number.isFinite(parsed.position) ? Number(parsed.position) : 0,
      duration: Number.isFinite(parsed.duration) ? Number(parsed.duration) : 0,
      still: typeof parsed.still === "string" && parsed.still.startsWith("data:image/") ? parsed.still : null,
    };
  } catch {
    return null;
  }
}

export function saveLastWatched(profileId: string | null, record: LastWatched) {
  try {
    localStorage.setItem(key(profileId), JSON.stringify(record));
  } catch {
    // Full or blocked: try again without the picture.
    try {
      localStorage.setItem(key(profileId), JSON.stringify({ ...record, still: null }));
    } catch {
      // A nicety.
    }
  }
}

export function clearLastWatched(profileId: string | null) {
  try {
    localStorage.removeItem(key(profileId));
  } catch {
    // A nicety.
  }
}

const STILL_WIDTH = 320;

/** The frame on screen as a small JPEG, or null if the browser won't give it up. */
export function captureStill(video: HTMLVideoElement): string | null {
  if (video.readyState < 2 || !video.videoWidth || !video.videoHeight) return null;
  try {
    const canvas = document.createElement("canvas");
    canvas.width = STILL_WIDTH;
    canvas.height = Math.round((STILL_WIDTH * video.videoHeight) / video.videoWidth);
    const context = canvas.getContext("2d");
    if (!context) return null;
    context.drawImage(video, 0, 0, canvas.width, canvas.height);
    return canvas.toDataURL("image/jpeg", 0.7);
  } catch {
    // A tainted canvas, or no canvas at all (tests).
    return null;
  }
}
