/**
 * What this browser can decode (PROPOSAL §6.1), in the shape
 * Playback::Capabilities reads. Asked of the browser itself, never guessed
 * from the user agent, and per path:
 * canPlayType for a file the <video> element opens directly; MediaSource
 * for what hls.js streams; canPlayType again for Safari's own HLS, which is
 * the same decoder. mediaCapabilities adds what a yes alone doesn't say —
 * whether 4K plays smoothly, whether HDR is really shown — once the page has
 * had a moment to ask (primeCapabilities); until then those are left
 * unlimited and the fallback ladder (R2) covers a wrong guess.
 */
export interface CapabilityProfile {
  hls: "native" | "mse" | "none";
  containers: string[];
  /** A file opened directly. */
  video: string[];
  audio: string[];
  /** The streaming path. */
  stream_video: string[];
  stream_audio: string[];
  /** The highest level each codec decodes at, ffprobe's numbering (H.264 51 = 5.1, HEVC 153 = 5.1, AV1 13 = 5.1). */
  levels: Record<string, number>;
  /** The tallest picture each codec decodes smoothly. */
  smooth: Record<string, number>;
  max_audio_channels: number;
  hdr: string[];
  /** How tall a conversion is made for this screen; a copy is never held to it. */
  max_height: number;
}

const VIDEO: Record<string, string> = {
  h264: 'video/mp4; codecs="avc1.640028"',
  h264_10: 'video/mp4; codecs="avc1.6e0028"',
  hevc: 'video/mp4; codecs="hvc1.1.6.L120.90"',
  hevc_10: 'video/mp4; codecs="hvc1.2.4.L120.90"',
  av1: 'video/mp4; codecs="av01.0.08M.08"',
  av1_10: 'video/mp4; codecs="av01.0.08M.10"',
  vp9: 'video/mp4; codecs="vp09.00.40.08"',
  vp9_10: 'video/mp4; codecs="vp09.02.40.10"',
  vp8: 'video/webm; codecs="vp8"',
};

const AUDIO: Record<string, string> = {
  aac: 'audio/mp4; codecs="mp4a.40.2"',
  mp3: 'audio/mp4; codecs="mp4a.69"',
  opus: 'audio/mp4; codecs="opus"',
  flac: 'audio/mp4; codecs="flac"',
  vorbis: 'audio/webm; codecs="vorbis"',
  alac: 'audio/mp4; codecs="alac"',
  ac3: 'audio/mp4; codecs="ac-3"',
  eac3: 'audio/mp4; codecs="ec-3"',
  dts: 'audio/mp4; codecs="dtsc"',
  truehd: 'audio/mp4; codecs="mlpa"',
};

/**
 * Each codec's levels, lowest first, as a codec string and ffprobe's number
 * for it: the highest that answers yes is the client's ceiling (Jellyfin's
 * browserDeviceProfile asks the same ladder).
 */
const LEVELS: Record<string, [string, number][]> = {
  h264: [
    ['video/mp4; codecs="avc1.640028"', 40],
    ['video/mp4; codecs="avc1.640029"', 41],
    ['video/mp4; codecs="avc1.64002a"', 42],
    ['video/mp4; codecs="avc1.640032"', 50],
    ['video/mp4; codecs="avc1.640033"', 51],
    ['video/mp4; codecs="avc1.640034"', 52],
  ],
  hevc: [
    ['video/mp4; codecs="hvc1.1.6.L120.90"', 120],
    ['video/mp4; codecs="hvc1.1.6.L123.90"', 123],
    ['video/mp4; codecs="hvc1.1.6.L150.90"', 150],
    ['video/mp4; codecs="hvc1.1.6.L153.90"', 153],
    ['video/mp4; codecs="hvc1.1.6.L156.90"', 156],
    ['video/mp4; codecs="hvc1.1.6.L180.90"', 180],
    ['video/mp4; codecs="hvc1.1.6.L183.90"', 183],
  ],
  av1: [
    ['video/mp4; codecs="av01.0.08M.08"', 8],
    ['video/mp4; codecs="av01.0.09M.08"', 9],
    ['video/mp4; codecs="av01.0.12M.08"', 12],
    ['video/mp4; codecs="av01.0.13M.08"', 13],
    ['video/mp4; codecs="av01.0.16M.08"', 16],
  ],
};

/** Whether hls.js can run here (MediaSource, or Safari's ManagedMediaSource). */
export function hasMediaSource(): boolean {
  return mediaSource() !== null;
}

function mediaSource(): { isTypeSupported(type: string): boolean } | null {
  const scope = globalThis as unknown as Record<string, { isTypeSupported(type: string): boolean } | undefined>;
  return scope.ManagedMediaSource ?? scope.MediaSource ?? null;
}

function isSafari(): boolean {
  return /^Apple/.test(navigator.vendor) && !/Chrome|CriOS|Edg/.test(navigator.userAgent);
}

function screenHeight(): number {
  const pixels = Math.max(window.screen.width, window.screen.height) * (window.devicePixelRatio || 1);
  if (pixels >= 3000) return 2160;
  if (pixels >= 2200) return 1440;
  if (pixels >= 1600) return 1080;
  return 720;
}

/** What mediaCapabilities said, once asked (primeCapabilities). */
const measured: { smooth: Record<string, number>; hdr: string[] | null } = { smooth: {}, hdr: null };

/** The output's channel count, where the browser says (a surround system says 6 or 8). */
function speakerChannels(): number {
  try {
    const Context = (globalThis as unknown as { AudioContext?: typeof AudioContext }).AudioContext;
    if (!Context) return 2;
    const context = new Context();
    const channels = context.destination.maxChannelCount || 2;
    void context.close();
    return channels;
  } catch {
    return 2;
  }
}

let cached: CapabilityProfile | null = null;

export function capabilityProfile(): CapabilityProfile {
  if (cached) return cached;
  const probe = document.createElement("video");
  const file = (type: string) => probe.canPlayType(type) !== "";
  const native = file("application/vnd.apple.mpegurl");
  // Safari's own HLS is the better path there; everywhere else, hls.js over
  // MediaSource, even where the browser has grown a native HLS of its own.
  const hls = native && isSafari() ? "native" : mediaSource() ? "mse" : native ? "native" : "none";
  const streamed = (type: string) => (hls === "native" ? file(type) : (mediaSource()?.isTypeSupported(type) ?? false));
  const video = Object.keys(VIDEO).filter((key) => file(VIDEO[key]));
  const audio = Object.keys(AUDIO).filter((key) => file(AUDIO[key]));
  const streamVideo = Object.keys(VIDEO).filter((key) => streamed(VIDEO[key]));
  const streamAudio = Object.keys(AUDIO).filter((key) => streamed(AUDIO[key]));
  const levels: Record<string, number> = {};
  for (const [codec, ladder] of Object.entries(LEVELS)) {
    const passing = ladder.filter(([type]) => streamed(type) || file(type)).map(([, level]) => level);
    if (passing.length > 0) levels[codec] = Math.max(...passing);
  }
  const hdrScreen = window.matchMedia?.("(dynamic-range: high)").matches ?? false;
  const claimedHdr = hdrScreen
    ? [
        ...(streamVideo.includes("hevc_10") || streamVideo.includes("av1_10") ? ["hdr10", "hlg"] : []),
        ...(file('video/mp4; codecs="dvh1.08.07"') ? ["dolby_vision"] : []),
      ]
    : [];
  // A surround codec hands its channels to the system to mix down; past
  // that, as many as the output has (Jellyfin's rule).
  const surround = audio.includes("eac3") || audio.includes("ac3");
  cached = {
    hls,
    containers: ["mp4", "webm"].filter((container) => file(`video/${container}`)),
    video,
    audio,
    stream_video: streamVideo,
    stream_audio: streamAudio,
    levels,
    smooth: measured.smooth,
    max_audio_channels: Math.min(Math.max(surround ? 6 : 2, speakerChannels()), 8),
    // mediaCapabilities' word when it has answered: the HDR a screen shows
    // as HDR, not washed out.
    hdr: measured.hdr ? claimedHdr.filter((format) => measured.hdr!.includes(format) || format === "dolby_vision") : claimedHdr,
    max_height: screenHeight(),
  };
  return cached;
}

interface DecodingQuery {
  codec: string;
  contentType: string;
  hdr?: "pq" | "hlg";
}

/**
 * Asks mediaCapabilities, in the background, what a codec string's yes
 * doesn't say: whether 2160p60 decodes smoothly, and whether HDR is shown
 * as HDR (Firefox matches an HDR screen and shows PQ washed out). Answers
 * land in the next profile; the first press of Play doesn't wait for them.
 */
export async function primeCapabilities(): Promise<void> {
  const capabilities = (navigator as Navigator & { mediaCapabilities?: MediaCapabilities }).mediaCapabilities;
  if (!capabilities?.decodingInfo) return;
  const type = mediaSource() ? "media-source" : "file";
  const ask = async ({ contentType, hdr }: DecodingQuery, height: number) => {
    try {
      const info = await capabilities.decodingInfo({
        type,
        video: {
          contentType,
          width: Math.round((height * 16) / 9),
          height,
          bitrate: height >= 2160 ? 40_000_000 : 10_000_000,
          framerate: 60,
          ...(hdr ? { transferFunction: hdr, colorGamut: "rec2020" as const } : {}),
        },
      } as MediaDecodingConfiguration);
      return info.supported && info.smooth;
    } catch {
      return false;
    }
  };
  const smooth: Record<string, number> = {};
  const codecs: DecodingQuery[] = [
    { codec: "h264", contentType: 'video/mp4; codecs="avc1.640033"' },
    { codec: "hevc", contentType: 'video/mp4; codecs="hvc1.1.6.L153.90"' },
    { codec: "av1", contentType: 'video/mp4; codecs="av01.0.12M.08"' },
    { codec: "vp9", contentType: 'video/mp4; codecs="vp09.00.51.08"' },
  ];
  for (const query of codecs) {
    if (!(await ask(query, 2160)) && (await ask(query, 1080))) smooth[query.codec] = 1080;
  }
  const hdr: string[] = [];
  if (await ask({ codec: "hevc", contentType: 'video/mp4; codecs="hvc1.2.4.L153.90"', hdr: "pq" }, 2160)) hdr.push("hdr10");
  if (await ask({ codec: "hevc", contentType: 'video/mp4; codecs="hvc1.2.4.L153.90"', hdr: "hlg" }, 2160)) hdr.push("hlg");
  measured.smooth = smooth;
  measured.hdr = hdr;
  cached = null;
}

const DEVICE_KEY = "stream_device";

/** This browser's device id, kept so its profile is recognised next time. */
export function deviceKey(): string {
  try {
    const existing = localStorage.getItem(DEVICE_KEY);
    if (existing) return existing;
    const minted = crypto.randomUUID();
    localStorage.setItem(DEVICE_KEY, minted);
    return minted;
  } catch {
    return "";
  }
}

let nativeHls: boolean | null = null;

/**
 * Whether the player uses the browser's own HLS rather than hls.js: Safari,
 * whose native player is the better one there. Asked of a <video> made for
 * the question, once, so the first render already knows (the player's own
 * element arrives a render later, and a first guess of "no" loaded hls.js
 * only to throw it away).
 */
export function prefersNativeHls(): boolean {
  if (nativeHls !== null) return nativeHls;
  try {
    const probe = document.createElement("video");
    nativeHls = probe.canPlayType("application/vnd.apple.mpegurl") !== "" && /^Apple/.test(navigator.vendor);
  } catch {
    nativeHls = false;
  }
  return nativeHls;
}

const ADAPTIVE_KEY = "stream_adaptive";

/**
 * Whether streams to this browser offer smaller versions to drop to on a
 * weak connection (docs/PERF_PROPOSAL.md › P8). Off by default: on the
 * household's network nothing needs them, and the server offers them to
 * anything outside it anyway.
 */
export function adaptiveQuality(): boolean {
  try {
    return localStorage.getItem(ADAPTIVE_KEY) === "1";
  } catch {
    return false;
  }
}

export function setAdaptiveQuality(on: boolean) {
  try {
    if (on) localStorage.setItem(ADAPTIVE_KEY, "1");
    else localStorage.removeItem(ADAPTIVE_KEY);
  } catch {
    // Without storage it stays off.
  }
}
