import { useCallback, useEffect, useRef, useState } from "react";

/** Where every file is brought to (LUFS). Films mix quieter, YouTube louder. */
const TARGET_LUFS = -20;
const MAX_BOOST_DB = 9;
const MAX_CUT_DB = -12;
/** Never push a peak past this (dBTP). */
const CEILING_DB = -1;
/** A boost smaller than this isn't worth sending the sound through Web Audio for. */
const BOOST_WORTH_DB = 1;

export interface Loudness {
  integrated: number;
  true_peak: number;
}

/** The gain (dB) that brings a file to the target without clipping its peaks. */
export function levellingGain(loudness: Loudness | null): number {
  if (!loudness) return 0;
  const wanted = Math.min(Math.max(TARGET_LUFS - loudness.integrated, MAX_CUT_DB), MAX_BOOST_DB);
  return Math.min(wanted, CEILING_DB - loudness.true_peak);
}

/**
 * Whether a file's sound has to go through Web Audio: for night mode's
 * compressor, or to be turned up. Turning it down is the element's own
 * volume (volumeScale), so a loud file — most of YouTube — plays as it is.
 * Sound through Web Audio drifts from the picture after a pause or a seek
 * in browsers (the picture is timed to a clock that doesn't count the
 * graph's latency), so it's only there when it's earning its keep.
 */
export function needsAudioGraph(loudness: Loudness | null, { levelling, night }: { levelling: boolean; night: boolean }): boolean {
  return night || (levelling && levellingGain(loudness) >= BOOST_WORTH_DB);
}

interface Graph {
  context: AudioContext;
  source: MediaElementAudioSourceNode;
  gain: GainNode;
  compressor: DynamicsCompressorNode;
}

const graphs = new WeakMap<HTMLVideoElement, Graph>();
/** Every element routed, for whether a context has anything playing. */
const routed = new Set<HTMLVideoElement>();

/**
 * One AudioContext for the app, started by the first click or key press
 * anywhere (docs/PERF_PROPOSAL.md › P22). A context only runs after a
 * gesture, and routing an element into one that isn't running silences it
 * — so the player used to route an element only once playing had begun,
 * and the sound dropped out as it was moved. With the context already
 * running from the press that started playing, the element is routed
 * before its first frame and never moved again.
 *
 * With it, at the same press, one at the other common rate (44.1 kHz
 * beside a 48 kHz device, or the other way about): an element is routed
 * into the one at its file's rate, so its sound isn't resampled on the
 * way into the graph, one more buffer for it to drift by.
 */
let shared: AudioContext | null = null;
const byRate = new Map<number, AudioContext>();
const COMMON_RATES = [44_100, 48_000] as const;
/** Suspended by a pause here, not by a browser that hasn't had a gesture: resumed at the next play. */
const restful = new WeakSet<AudioContext>();

function primeAudio() {
  try {
    shared ??= new AudioContext();
    if (shared.state === "suspended" && !restful.has(shared)) void shared.resume().catch(() => undefined);
    byRate.set(shared.sampleRate, shared);
    for (const rate of COMMON_RATES) {
      if (byRate.has(rate)) continue;
      try {
        byRate.set(rate, new AudioContext({ sampleRate: rate }));
      } catch {
        // A browser that won't make one at this rate: the shared one does.
        byRate.set(rate, shared);
      }
    }
    for (const context of byRate.values()) {
      if (context.state === "suspended" && !restful.has(context)) void context.resume().catch(() => undefined);
    }
  } catch {
    // No Web Audio here: levelling falls back to the element's volume.
  }
}

/** Running, or only resting since a pause here: an element can be routed into it. */
function usable(context: AudioContext | null | undefined): context is AudioContext {
  return !!context && (context.state === "running" || (context.state === "suspended" && restful.has(context)));
}

/** The context to route a file at this rate into: its own rate's if that one's running, else the shared one. */
function contextFor(rate: number | null): AudioContext | null {
  const matched = rate ? byRate.get(rate) : undefined;
  if (usable(matched)) return matched;
  return usable(shared) ? shared : null;
}

/** A context with something to play wakes up. */
function wake(context: AudioContext) {
  restful.delete(context);
  if (context.state === "suspended") void context.resume().catch(() => undefined);
}

/**
 * A context with nothing playing into it rests, rather than running on
 * with silence while the element's sound waits in its buffers. Shared by
 * every routed element, so only when none of them is playing.
 */
function rest(context: AudioContext) {
  for (const element of routed) {
    if (!element.isConnected) {
      routed.delete(element);
      continue;
    }
    if (graphs.get(element)?.context === context && !element.paused) return;
  }
  if (context.state !== "running") return;
  restful.add(context);
  void context.suspend().catch(() => restful.delete(context));
}

/**
 * Plays, and if the browser won't let sound start without a gesture,
 * plays muted instead (`onMuted` says so). Only that refusal mutes: a play
 * cut short by a load (AbortError) isn't the browser refusing sound.
 */
export function playOrMute(element: HTMLMediaElement, onMuted?: () => void) {
  void element.play().catch((reason: unknown) => {
    if (!(reason instanceof DOMException) || reason.name !== "NotAllowedError") return;
    element.muted = true;
    onMuted?.();
    void element.play().catch(() => undefined);
  });
}

/** Listens for the gestures that start the shared context, until it has. */
export function installAudioPriming(target: Document = document): () => void {
  const onGesture = () => {
    primeAudio();
    if (shared?.state === "running") remove();
  };
  const events = ["pointerdown", "keydown", "touchend"] as const;
  const remove = () => {
    for (const name of events) target.removeEventListener(name, onGesture, true);
  };
  for (const name of events) target.addEventListener(name, onGesture, true);
  return remove;
}

/**
 * Routes an element's audio through a gain and a compressor — only when
 * a context is running (or resting since a pause), and only once per
 * element: an element routed into a context that isn't running goes
 * silent (WebKit won't even autoplay it), and moving one that's already
 * playing drops its sound.
 */
function connectGraph(video: HTMLVideoElement, rate: number | null): Graph | null {
  const existing = graphs.get(video);
  if (existing) return existing;
  const context = contextFor(rate);
  if (!context) return null;
  try {
    const source = context.createMediaElementSource(video);
    const gain = context.createGain();
    const compressor = context.createDynamicsCompressor();
    compressor.threshold.value = -40;
    compressor.knee.value = 20;
    compressor.ratio.value = 8;
    compressor.attack.value = 0.003;
    compressor.release.value = 0.25;
    source.connect(gain);
    gain.connect(context.destination);
    const graph: Graph = { context, source, gain, compressor };
    graphs.set(video, graph);
    routed.add(video);
    wake(context);
    return graph;
  } catch {
    return null;
  }
}

/** Where a routed element's sound goes, for the stats overlay: null when it plays as it is. */
export interface AudioGraphInfo {
  sampleRate: number;
  /** Seconds the graph itself holds the sound (baseLatency) and the device after it (outputLatency, where known). */
  baseLatency: number;
  outputLatency: number | null;
  state: AudioContextState;
}

export function audioGraphInfo(video: HTMLVideoElement): AudioGraphInfo | null {
  const graph = graphs.get(video);
  if (!graph) return null;
  const { context } = graph;
  return {
    sampleRate: context.sampleRate,
    baseLatency: context.baseLatency ?? 0,
    outputLatency: "outputLatency" in context ? context.outputLatency : null,
    state: context.state,
  };
}

/** How the sound reaches the speakers, as the overlay says it. */
export interface SoundPath {
  levelling: boolean;
  night: boolean;
  /** The file's sound's rate (Hz), when it reaches the element as it is. */
  sampleRate: number | null;
  /** Times it was lined up with the picture again after a pause or seek. */
  resyncs: number;
}

const khz = (hz: number) => `${(hz / 1000).toFixed(1).replace(/\.0$/, "")} kHz`;
const ms = (seconds: number) => `${Math.round(seconds * 1000)} ms`;

/** "Web Audio (night mode, +4.0 dB) · 48 kHz from 44.1 kHz · latency 10 ms + 40 ms · resynced 2×", or the element's own. */
export function soundLabel(sound: SoundPath, graph: AudioGraphInfo | null, loudness: Loudness | null): string {
  const gain = sound.levelling ? levellingGain(loudness) : 0;
  const db = `${gain >= 0 ? "+" : ""}${gain.toFixed(1)} dB`;
  if (!graph) {
    const as = sound.levelling && gain < 0 ? `volume ${db}` : "as it is";
    return `Element, ${as}${sound.sampleRate ? ` · ${khz(sound.sampleRate)}` : ""}`;
  }
  const why = [sound.night ? "night mode" : null, sound.levelling ? db : null].filter(Boolean).join(", ");
  const rate = sound.sampleRate && sound.sampleRate !== graph.sampleRate ? `${khz(graph.sampleRate)} from ${khz(sound.sampleRate)}` : khz(graph.sampleRate);
  const latency = `latency ${ms(graph.baseLatency)}${graph.outputLatency !== null ? ` + ${ms(graph.outputLatency)}` : ""}`;
  const state = graph.state === "running" ? "" : ` (${graph.state})`;
  return [`Web Audio${why ? ` (${why})` : ""}${state}`, rate, latency, `resynced ${sound.resyncs}×`].join(" · ");
}

/** Elements in the middle of a resync's seek: not the viewer's, so not timed as one. */
const resyncing = new WeakSet<HTMLMediaElement>();

/** Whether the element's seek now is a resync's, not the viewer's. */
export function isResyncSeek(element: HTMLMediaElement): boolean {
  return resyncing.has(element);
}

/** How long after playing resumes the sound is lined up again: once it's flowing, so the seek flushes what built up. */
const RESYNC_AFTER_MS = 300;

/**
 * Keeps a routed element's sound with its picture. After a pause or a
 * seek, once it's playing again, the element is moved to where it is:
 * that seek flushes the sound buffered between the element and the graph,
 * which a pause or a seek can leave a little more of each time. And while
 * nothing routed is playing, the context rests (rest), so the graph isn't
 * running ahead on silence. The first start isn't touched: the element was
 * routed before its first frame. Returns what stops it.
 */
export function keepInSync(video: HTMLVideoElement, context: AudioContext, onResync: () => void): () => void {
  let started = !video.paused && video.readyState > 2;
  let restarted = false;
  let timer: number | undefined;
  const onPause = () => {
    if (started) restarted = true;
    window.clearTimeout(timer);
    rest(context);
  };
  const onPlay = () => wake(context);
  const onSeeking = () => {
    if (resyncing.has(video)) return;
    if (started) restarted = true;
    window.clearTimeout(timer);
  };
  const onSeeked = () => {
    resyncing.delete(video);
  };
  const onPlaying = () => {
    if (!started) {
      started = true;
      return;
    }
    if (!restarted) return;
    window.clearTimeout(timer);
    timer = window.setTimeout(() => {
      if (video.paused || video.seeking || !restarted) return;
      restarted = false;
      resyncing.add(video);
      const at = video.currentTime;
      video.currentTime = at;
      onResync();
    }, RESYNC_AFTER_MS);
  };
  // Another source on the same element is another start.
  const onEmptied = () => {
    started = false;
    restarted = false;
    window.clearTimeout(timer);
  };
  const events: [string, () => void][] = [
    ["pause", onPause],
    ["ended", onPause],
    ["play", onPlay],
    ["seeking", onSeeking],
    ["seeked", onSeeked],
    ["playing", onPlaying],
    ["emptied", onEmptied],
  ];
  for (const [name, listener] of events) video.addEventListener(name, listener);
  return () => {
    window.clearTimeout(timer);
    for (const [name, listener] of events) video.removeEventListener(name, listener);
  };
}

/**
 * Volume levelling and night mode (PROPOSAL §7.3), in the browser: the
 * measured loudness becomes a gain, and night mode a compressor that lifts
 * dialogue and tames explosions. Nothing is re-encoded.
 *
 * `route` is called by the player as soon as its element exists, before
 * it has any data — when the file needs the graph (needsAudioGraph): the
 * element goes through it from its first frame, or — if no context is
 * running (no gesture yet, or Safari's own HLS, which can't feed Web
 * Audio) — plays as it is for the whole session, and a quieter-than-target
 * file can only be turned down, through the element's volume
 * (volumeScale). Night mode turned on mid-film routes it then.
 *
 * `sampleRate` is the file's sound's, for the context it's routed into.
 * `onResync` is told each time the sound is lined up with the picture again.
 */
export function useAudioLevelling(
  video: HTMLVideoElement | null,
  loudness: Loudness | null,
  { levelling, night, webAudio, sampleRate = null }: { levelling: boolean; night: boolean; webAudio: boolean; sampleRate?: number | null },
  onResync?: () => void,
): { routed: boolean; route: () => void } {
  const [graph, setGraph] = useState<Graph | null>(null);
  const webAudioRef = useRef(webAudio);
  webAudioRef.current = webAudio;
  const rateRef = useRef(sampleRate);
  rateRef.current = sampleRate;
  const onResyncRef = useRef(onResync);
  onResyncRef.current = onResync;

  const route = useCallback(() => {
    if (!video || !webAudioRef.current) return;
    const nodes = connectGraph(video, rateRef.current);
    if (nodes) setGraph(nodes);
  }, [video]);

  // Already routed (the same element, a setting changed): keep using it.
  useEffect(() => {
    const nodes = video ? graphs.get(video) : undefined;
    setGraph(nodes && webAudio ? nodes : null);
  }, [video, webAudio]);

  useEffect(() => {
    if (!video || !graph) return;
    return keepInSync(video, graph.context, () => onResyncRef.current?.());
  }, [video, graph]);

  useEffect(() => {
    if (!graph) return;
    const gainDb = levelling ? levellingGain(loudness) : 0;
    const { context, source, gain, compressor } = graph;
    source.disconnect();
    gain.disconnect();
    compressor.disconnect();
    // Night mode's compressor pulls everything down; its make-up gain puts
    // dialogue back where it was.
    gain.gain.value = 10 ** ((gainDb + (night ? 8 : 0)) / 20);
    if (night) {
      source.connect(compressor);
      compressor.connect(gain);
    } else {
      source.connect(gain);
    }
    gain.connect(context.destination);
  }, [graph, loudness, levelling, night]);

  return { routed: graph !== null, route };
}

/** Without Web Audio, the most levelling can do: turn a loud file down. */
export function volumeScale(loudness: Loudness | null, levelling: boolean, webAudio: boolean): number {
  if (webAudio || !levelling) return 1;
  const gainDb = levellingGain(loudness);
  return gainDb < 0 ? 10 ** (gainDb / 20) : 1;
}
