import type Hls from "hls.js/light";
import { hlsMediaFailure, type PlayFailure } from "@/components/player/failure";
import { islandsFrom, type Milestone } from "@/components/player/timing";
import { watchForPicture, watchPicture } from "@/components/player/watchdog";

export interface SourceHandlers {
  /** Which version of an adaptive stream is playing ("Original", "720p"). */
  onQuality?: (label: string | null) => void;
  /** Playback can't go on as it is: the player falls back a rung. */
  onFailure: (failure: PlayFailure) => void;
  /** hls.js can't run here at all. */
  onUnsupported: () => void;
  /** A step of starting landed: the media playlist, the init segment, the first fragment. */
  onMilestone?: (name: Milestone) => void;
  /**
   * Playback helped itself along and carried on: what from, in hls.js's
   * name for it or the player's own ("picture froze"). For the Playback
   * decisions page — a stream that needs a lot of this isn't right.
   */
  onRecovery?: (what: string, cause?: string) => void;
}

/**
 * Why, in the browser's words: hls.js's error (which carries the element's
 * when it has one) and the element's own, for a decoder that gave up
 * ("mediaSourceRequiresReset" alone said nothing on 2026-10-08).
 */
function causeOf(error: Error | undefined, element: HTMLVideoElement): string | undefined {
  const media = element.error ? `MediaError ${element.error.code}: ${element.error.message}` : "";
  const said = error?.message ?? "";
  const cause = media && !said.includes(element.error?.message || media) ? [said, media].filter(Boolean).join(" · ") : said;
  return cause ? cause.slice(0, 300) : undefined;
}

/** A source on an element. */
export interface Attached {
  detach: () => void;
  /** How far ahead to buffer from now on, in seconds (a stream through hls.js; nothing otherwise). */
  setBufferLength: (seconds: number) => void;
}

/**
 * Attaches a session's source to a video element (PROPOSAL §7.3): the file
 * or HLS as the browser plays it itself, or HLS through hls.js — starting
 * at full quality (on the LAN nothing ever drops) and only falling to a
 * smaller version when the network really can't keep up.
 */
export function attachSource(
  element: HTMLVideoElement,
  source: { kind: "file" | "hls"; url: string },
  from: number,
  nativeHls: boolean,
  handlers: SourceHandlers,
  /**
   * live: a live playlist (PROPOSAL §7.8), started near its newest segment.
   * fallback: a title's play, which falls back a rung when it can't go on
   * (R2): a picture that never comes, or keeps freezing, is a failure too.
   */
  config: { maxBufferLength?: number; live?: boolean; fallback?: boolean } = {},
): Attached {
  if (source.kind === "file" || nativeHls) {
    element.src = source.url;
    // The element's own errors reach the player through onError; a picture
    // that never comes reaches nothing else.
    const stopLooking = config.fallback ? watchForPicture(element, () => handlers.onFailure({ failureClass: "decode", cause: "sound with no picture" })) : () => undefined;
    return {
      detach: () => {
        stopLooking();
        element.removeAttribute("src");
        element.load();
      },
      setBufferLength: () => undefined,
    };
  }
  let hls: Hls | null = null;
  let cancelled = false;
  let bufferLength = config.maxBufferLength ?? 60;
  let stopWatching = () => {};
  let stopLooking = () => {};
  void import("hls.js/light").then(({ default: HlsJs }) => {
    if (cancelled) return;
    if (!HlsJs.isSupported()) {
      handlers.onUnsupported();
      return;
    }
    const instance = new HlsJs({
      startPosition: from,
      // A live stream's relay: start two segments behind its newest. No
      // ceiling on how far behind: pausing and going back are allowed.
      ...(config.live ? { liveSyncDurationCount: 2 } : {}),
      maxBufferLength: bufferLength,
      backBufferLength: 90,
      abrEwmaDefaultEstimate: 50_000_000,
      // The server holds a segment request until the transcoder has made it
      // (Playback::Segments::WAIT, 20 s): hls.js's own 10 s would give up
      // on it and ask again while the first is still being answered.
      fragLoadPolicy: {
        default: {
          maxTimeToFirstByteMs: 25_000,
          maxLoadTimeMs: 120_000,
          timeoutRetry: { maxNumRetry: 2, retryDelayMs: 0, maxRetryDelayMs: 0 },
          errorRetry: { maxNumRetry: 6, retryDelayMs: 1_000, maxRetryDelayMs: 8_000 },
        },
      },
    });
    hls = instance;
    instance.on(HlsJs.Events.MANIFEST_PARSED, (_event, data) => {
      instance.startLevel = data.levels.length - 1;
    });
    instance.on(HlsJs.Events.LEVEL_LOADED, () => handlers.onMilestone?.("manifest"));
    instance.on(HlsJs.Events.FRAG_LOADED, (_event, data) => {
      if (data.frag.sn === "initSegment") handlers.onMilestone?.("init");
    });
    instance.on(HlsJs.Events.LEVEL_SWITCHED, (_event, data) => {
      const level = instance.levels[data.level];
      handlers.onQuality?.(level ? (data.level === instance.levels.length - 1 ? "Original" : `${level.height}p`) : null);
    });
    // A network hiccup or a decoder stumble is worth one more try each
    // before telling anyone. Network trouble counts per stretch, not per
    // stream — hours of live TV can have more than three — and so does a
    // decoder's: one that keeps stumbling within a minute is given up on,
    // one that stumbled once an hour ago isn't.
    let reloads = 0;
    let recoveries = 0;
    let lastRecovery = 0;
    let failed = false;
    const fail = (failure: PlayFailure) => {
      if (failed) return;
      failed = true;
      handlers.onFailure(failure);
    };
    let flushedFrom: number | null = null;
    instance.on(HlsJs.Events.FRAG_BUFFERED, () => {
      reloads = 0;
      flushedFrom = null;
      handlers.onMilestone?.("fragment");
    });
    instance.on(HlsJs.Events.ERROR, (_event, data) => {
      // The transcoder gave up on this stream (Playback::Segments::Failed):
      // asking again won't help, a rung down will — whether or not hls.js,
      // with no other level to try, calls it fatal.
      if (data.response?.code === 424) {
        // (hls.js has the status's text, not the body: the server records its own why.)
        fail({ failureClass: "server", cause: "the transcoder gave up (424)" });
        return;
      }
      if (!data.fatal) {
        // What hls.js got past by itself — a hole hopped, a fragment asked
        // for again — is still worth knowing about. A plain wait for data
        // isn't (the player reports that as a stall, with how long), nor
        // is a fetch a seek called off.
        const aborted = (data.details as string) === "aborted";
        if (data.details !== HlsJs.ErrorDetails.BUFFER_STALLED_ERROR && !aborted) handlers.onRecovery?.(data.details, causeOf(data.error, element));
        return;
      }
      const cause = causeOf(data.error, element);
      if (data.type === HlsJs.ErrorTypes.NETWORK_ERROR) {
        if (reloads < 3) {
          reloads += 1;
          handlers.onRecovery?.(`${data.details}, loading again`, cause);
          // A playlist that didn't load is loaded again; a fragment, fetched again.
          if (data.details === HlsJs.ErrorDetails.MANIFEST_LOAD_ERROR || data.details === HlsJs.ErrorDetails.MANIFEST_LOAD_TIMEOUT) instance.loadSource(source.url);
          else instance.startLoad();
          return;
        }
        fail({ failureClass: "network", cause: String(data.response?.text || cause || data.details).slice(0, 300) });
        return;
      }
      if (data.type === HlsJs.ErrorTypes.MEDIA_ERROR) {
        if (performance.now() - lastRecovery > 60_000) recoveries = 0;
        lastRecovery = performance.now();
        if (recoveries < 3) {
          recoveries += 1;
          // The second stumble in a row tries the sound the other way too
          // (Jellyfin's htmlMediaHelper): an audio codec MSE misread.
          if (recoveries === 2) instance.swapAudioCodec();
          handlers.onRecovery?.(`${data.details}, media recovered`, cause);
          instance.recoverMediaError();
          return;
        }
        fail(hlsMediaFailure(data.details, cause));
        return;
      }
      fail({ failureClass: "decode", cause: String(cause || data.details).slice(0, 300) });
    });
    // A seek leaves what was buffered ahead of it as an island, and
    // filling the buffer up to one loses its first GOP of picture
    // (islandsFrom). So before a fragment is fetched, anything buffered
    // past the piece it joins is let go of; it comes back from the
    // browser's own cache, since a stream's segments never change under
    // their address. Done here rather than at the seek, where hls.js is
    // still deciding whether the stream has ended.
    let flushing = false;
    instance.on(HlsJs.Events.BUFFER_FLUSHED, () => {
      flushing = false;
    });
    instance.on(HlsJs.Events.FRAG_LOADING, (_event, data) => {
      if (flushing || data.frag.sn === "initSegment") return;
      const from = islandsFrom(element.buffered, data.frag.start);
      // The same place twice with nothing buffered in between is a sliver
      // the browser kept, not an island.
      if (from === null || from === flushedFrom) return;
      flushing = true;
      flushedFrom = from;
      instance.trigger(HlsJs.Events.BUFFER_FLUSHING, { startOffset: from, endOffset: Number.POSITIVE_INFINITY, type: null });
    });
    // The sound carrying on over a frozen picture is neither a stall nor
    // an error to anything else (watchdog.ts): everything buffered is let
    // go of, and hls.js fetches where the viewer is again.
    // Three times in a minute and a half is a picture that won't decode,
    // not a hole in the buffer.
    const freezes: number[] = [];
    stopWatching = watchPicture(element, () => {
      const now = performance.now();
      freezes.push(now);
      while (freezes.length > 0 && now - freezes[0]! > 90_000) freezes.shift();
      if (config.fallback && freezes.length >= 3) {
        fail({ failureClass: "decode", cause: "the picture froze three times" });
        return;
      }
      handlers.onRecovery?.("picture froze");
      instance.trigger(HlsJs.Events.BUFFER_FLUSHING, { startOffset: 0, endOffset: Number.POSITIVE_INFINITY, type: null });
    });
    if (config.fallback) stopLooking = watchForPicture(element, () => fail({ failureClass: "decode", cause: "sound with no picture" }));
    instance.loadSource(source.url);
    instance.attachMedia(element);
  });
  return {
    detach: () => {
      cancelled = true;
      stopWatching();
      stopLooking();
      hls?.destroy();
    },
    setBufferLength: (seconds) => {
      bufferLength = seconds;
      if (hls) hls.config.maxBufferLength = seconds;
    },
  };
}
