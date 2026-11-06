// hls.js's light build (no alternate audio, subtitles or DRM, which Stream
// doesn't use) ships without its own declarations; its API is the full
// build's.
declare module "hls.js/light" {
  export * from "hls.js";
  export { default } from "hls.js";
}
