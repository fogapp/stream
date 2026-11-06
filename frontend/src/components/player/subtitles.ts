import { useEffect } from "react";
import type { SubtitleTrack } from "@/types";

const LANGUAGE_KEY = "stream_subtitle_language";

function languageName(code: string | null): string | null {
  if (!code) return null;
  try {
    return new Intl.DisplayNames(undefined, { type: "language" }).of(code) ?? code;
  } catch {
    return code;
  }
}

export function subtitleLabel(track: SubtitleTrack): string {
  const parts = [track.title ?? languageName(track.language) ?? "Unknown"];
  if (track.title && track.language) parts.push(languageName(track.language) ?? track.language);
  if (track.forced) parts.push("Forced");
  if (track.hearing_impaired) parts.push("SDH");
  if (track.external) parts.push("External");
  return parts.join(" · ");
}

/**
 * The track to start with: the language chosen last time, else a forced
 * track (the foreign-dialogue lines a film expects you to see), else none.
 */
export function initialSubtitle(all: SubtitleTrack[]): string | null {
  // Burned-in ones are chosen by hand: they restart the stream.
  const tracks = all.filter((track) => !track.burn);
  let remembered: string | null = null;
  try {
    remembered = localStorage.getItem(LANGUAGE_KEY);
  } catch {
    remembered = null;
  }
  if (remembered === "off") return tracks.find((track) => track.forced)?.id ?? null;
  const preferred = remembered ? tracks.find((track) => track.language === remembered && !track.forced) : undefined;
  return (preferred ?? tracks.find((track) => track.forced))?.id ?? null;
}

export function rememberSubtitle(track: SubtitleTrack | null) {
  try {
    localStorage.setItem(LANGUAGE_KEY, track?.language ?? "off");
  } catch {
    // A nicety.
  }
}

/** How long a track still being taken out of its file is waited for, at most. */
export const SUBTITLE_PATIENCE_MS = 15 * 60_000;

/**
 * Resolves once the track at `url` can be fetched (docs/APPLETV_STALLS.md ›
 * R5): Stream answers 503 with Retry-After while a job takes a track out of
 * its file, and none of <track>, JASSUB or libpgs asks twice. Any other
 * answer — the track, or why there isn't one — ends the wait; the renderer
 * then fetches it as it would have (the answer is cached for an hour).
 * Rejects when aborted or after SUBTITLE_PATIENCE_MS.
 */
export async function whenSubtitleReady(
  url: string,
  signal: AbortSignal,
  { fetcher = fetch, sleep = abortableSleep, patienceMs = SUBTITLE_PATIENCE_MS }: {
    fetcher?: typeof fetch;
    sleep?: (ms: number, signal: AbortSignal) => Promise<void>;
    patienceMs?: number;
  } = {},
): Promise<void> {
  const giveUpAt = Date.now() + patienceMs;
  for (;;) {
    const response = await fetcher(url, { signal });
    if (response.status !== 503) return;
    const retryAfter = Number(response.headers.get("Retry-After"));
    const waitMs = Math.min(Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter * 1000 : 10_000, 30_000);
    if (Date.now() + waitMs > giveUpAt) throw new Error("subtitle track still not ready");
    await sleep(waitMs, signal);
  }
}

function abortableSleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const timer = window.setTimeout(resolve, ms);
    signal.addEventListener("abort", () => {
      window.clearTimeout(timer);
      reject(signal.reason);
    }, { once: true });
  });
}

/**
 * Renders the chosen subtitle over the video (PROPOSAL §6.2): WebVTT with
 * the browser's own <track>, ASS with JASSUB (libass in WASM) using the
 * file's own fonts, PGS with libpgs. A renderer that won't start falls back
 * to WebVTT where there is one.
 */
export function useSubtitles(video: HTMLVideoElement | null, track: SubtitleTrack | null, fonts: string[]) {
  useEffect(() => {
    if (!video || !track) return;
    let disposed = false;
    let cleanup: () => void = () => undefined;

    const showVtt = (url: string) => {
      const element = document.createElement("track");
      element.kind = "subtitles";
      element.src = url;
      element.srclang = track.language ?? "und";
      element.default = true;
      video.appendChild(element);
      element.track.mode = "showing";
      cleanup = () => element.remove();
    };

    const waiting = new AbortController();
    const ready = (url: string) => whenSubtitleReady(url, waiting.signal);
    if (track.format === "ass" && track.urls.ass) {
      const url = track.urls.ass;
      void ready(url)
        .then(() => import("jassub"))
        .then(({ default: JASSUB }) => {
          if (disposed) return;
          const renderer = new JASSUB({ video, subUrl: url, fonts });
          cleanup = () => void renderer.destroy();
        })
        .catch(() => {
          if (!disposed && track.urls.vtt) showVtt(track.urls.vtt);
        });
    } else if (track.format === "pgs" && track.urls.sup) {
      const url = track.urls.sup;
      void ready(url)
        .then(() => Promise.all([import("libpgs"), import("libpgs/dist/libpgs.worker.js?url")]))
        .then(([{ PgsRenderer }, worker]) => {
          if (disposed) return;
          const renderer = new PgsRenderer({ video, subUrl: url, workerUrl: worker.default });
          cleanup = () => renderer.dispose();
        })
        .catch(() => undefined);
    } else if (track.urls.vtt) {
      const url = track.urls.vtt;
      void ready(url)
        .then(() => {
          if (!disposed) showVtt(url);
        })
        .catch(() => undefined);
    }

    return () => {
      disposed = true;
      waiting.abort();
      cleanup();
    };
  }, [video, track, fonts]);
}
