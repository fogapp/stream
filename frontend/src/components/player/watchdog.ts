/** How often the picture is looked at. */
const CHECK_MS = 500;
/** This much of the film played without a frame decoded is a frozen picture. */
const FROZEN_AFTER_S = 2;
/** After saying so, not again for this long: the reload it prompts needs a moment. */
const REST_MS = 15_000;

/**
 * Watches for the sound carrying on over a frozen picture: the clock moving
 * while no frame is decoded. A stream's buffer can be missing a GOP of
 * picture that the browser still reports as buffered (timing.ts ›
 * islandsFrom), so nothing else notices — neither a stall nor an error
 * happens. `onFrozen` is told, at most every fifteen seconds.
 *
 * Not while paused, seeking, waiting for data, or out of sight: a hidden
 * tab's video isn't decoded at all. Returns what stops the watch.
 */
export function watchPicture(element: HTMLVideoElement, onFrozen: () => void): () => void {
  if (typeof element.getVideoPlaybackQuality !== "function") return () => undefined;
  let frames = -1;
  let since = element.currentTime;
  let restUntil = 0;
  const check = () => {
    const decoded = element.getVideoPlaybackQuality().totalVideoFrames;
    const idle = element.paused || element.seeking || element.readyState < 3 || element.videoWidth === 0 || document.visibilityState !== "visible";
    if (decoded !== frames || idle) {
      frames = decoded;
      since = element.currentTime;
      return;
    }
    if (element.currentTime - since < FROZEN_AFTER_S * (element.playbackRate || 1)) return;
    since = element.currentTime;
    if (performance.now() < restUntil) return;
    restUntil = performance.now() + REST_MS;
    onFrozen();
  };
  const timer = window.setInterval(check, CHECK_MS);
  return () => window.clearInterval(timer);
}

/** This much of the film played with no picture at all is a picture that won't come. */
const NO_PICTURE_AFTER_S = 4;

/**
 * Watches for the sound playing with no picture ever shown: the browser
 * opened the stream, its clock runs, and the video never decoded — a
 * profile its decoder doesn't take (4:2:2 H.264, HEVC its hardware
 * refuses), which neither an error nor a stall reports.
 * On every path: a file, native HLS
 * and hls.js. `onMissing` is told once.
 */
export function watchForPicture(element: HTMLVideoElement, onMissing: () => void): () => void {
  let since: number | null = null;
  let told = false;
  const check = () => {
    if (told) return;
    const quality = typeof element.getVideoPlaybackQuality === "function" ? element.getVideoPlaybackQuality() : null;
    const shown = element.videoWidth > 0 && (quality === null || quality.totalVideoFrames > 0);
    if (shown) {
      told = true;
      return;
    }
    const idle = element.paused || element.seeking || element.readyState < 2 || document.visibilityState !== "visible";
    if (idle) {
      since = null;
      return;
    }
    since ??= element.currentTime;
    if (element.currentTime - since < NO_PICTURE_AFTER_S * (element.playbackRate || 1)) return;
    told = true;
    onMissing();
  };
  const timer = window.setInterval(check, CHECK_MS);
  return () => window.clearInterval(timer);
}
