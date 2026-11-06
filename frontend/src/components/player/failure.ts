import type { NavigateFunction } from "react-router-dom";
import { fromTv, tvPath } from "@/lib/tv";
import { toast } from "@/components/ui/Toast";
import type { FailureClass, PlayableKind, PlaybackSessionInfo } from "@/types";

/**
 * Why a play can't go on as it is, in the classes the server falls back by
 * (PlaybackSession::FailureClass), with
 * the browser's own words for the Playback page.
 */
export interface PlayFailure {
  failureClass: FailureClass;
  cause: string;
}

/** MediaError's codes (the constants aren't everywhere a test runs). */
const MEDIA_ERR = { aborted: 1, network: 2, decode: 3 } as const;

/** The element's own error: null for one the viewer caused (an abort). */
export function mediaErrorFailure(error: MediaError | null): PlayFailure | null {
  if (!error || error.code === MEDIA_ERR.aborted) return null;
  const cause = `MediaError ${error.code}: ${error.message}`.slice(0, 300);
  switch (error.code) {
    case MEDIA_ERR.network:
      return { failureClass: "network", cause };
    case MEDIA_ERR.decode:
      return { failureClass: "decode", cause };
    default:
      return { failureClass: "unsupported", cause };
  }
}

/** hls.js's errors that mean the browser won't take this stream at all, rather than couldn't decode it. */
const UNSUPPORTED_DETAILS = new Set(["bufferAddCodecError", "manifestIncompatibleCodecsError", "bufferIncompatibleCodecsError"]);

/** A media error hls.js couldn't recover from. */
export function hlsMediaFailure(details: string, cause: string | undefined): PlayFailure {
  return { failureClass: UNSUPPORTED_DETAILS.has(details) ? "unsupported" : "decode", cause: (cause ? `${details}: ${cause}` : details).slice(0, 300) };
}

/** What the viewer is told when a play stops for good, by why: the browser's own words stay on the Playback page. */
const FAILURE_MESSAGES: Record<FailureClass, string> = {
  decode: "This browser couldn't decode the video.",
  unsupported: "This browser can't play this format.",
  stalled: "The stream stopped arriving.",
  network: "The connection to the server was lost.",
  server: "The server couldn't keep the stream going.",
};

export function failureMessage(failure: PlayFailure): string {
  return FAILURE_MESSAGES[failure.failureClass];
}

/**
 * A play that stopped, said where it stays until dismissed (the top right):
 * the player is gone from the screen by the time it's read.
 */
export function reportPlayFailure(title: string | null, message: string) {
  toast.error(message, { title: title ? `Couldn't play ${title}` : "Couldn't play this", persistent: true });
}

/** A play that will keep pausing because its file's storage can't keep up: better said now than left to look like a fault. */
export function reportFallingBehind(session: Pick<PlaybackSessionInfo, "falls_behind" | "title">) {
  if (session.falls_behind) toast.info("Its storage can't keep up, so it will keep stopping to load.", { title: session.title });
}

/** A title's own page, when there's no session to say (one that never started). An episode's is its show's, which isn't known here. */
const TITLE_PAGES: Record<PlayableKind, ((id: string) => string) | null> = {
  movie: (id) => `/movie/${id}`,
  video: (id) => `/video/${id}`,
  clip: (id) => `/clip/${id}`,
  episode: null,
  extra: null,
};

/**
 * Off a player's own route after a play failed: back where it was pressed,
 * or — opened straight from a link, with nowhere in the app to go back to —
 * to the title's page (the TV's, from the TV layout).
 */
export function leavePlayer(navigate: NavigateFunction, kind: PlayableKind, id: string) {
  const index = (window.history.state as { idx?: number } | null)?.idx ?? 0;
  if (index > 0) {
    navigate(-1);
    return;
  }
  const page = TITLE_PAGES[kind]?.(id) ?? "/";
  navigate(fromTv() ? tvPath(page) : page, { replace: true });
}
