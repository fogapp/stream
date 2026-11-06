import { useCallback, useEffect, useRef, useState } from "react";

/** Where every file is brought to (LUFS). Films mix quieter, YouTube louder. */
const TARGET_LUFS = -20;
const MAX_BOOST_DB = 9;
const MAX_CUT_DB = -12;
/** Never push a peak past this (dBTP). */
const CEILING_DB = -1;

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

interface Graph {
  context: AudioContext;
  source: MediaElementAudioSourceNode;
  gain: GainNode;
  compressor: DynamicsCompressorNode;
}

const graphs = new WeakMap<HTMLVideoElement, Graph>();

/**
 * One AudioContext for the app, started by the first click or key press
 * anywhere (docs/PERF_PROPOSAL.md › P22). A context only runs after a
 * gesture, and routing an element into one that isn't running silences it
 * — so the player used to route an element only once playing had begun,
 * and the sound dropped out as it was moved. With the context already
 * running from the press that started playing, the element is routed
 * before its first frame and never moved again.
 */
let shared: AudioContext | null = null;

function primeAudio() {
  try {
    shared ??= new AudioContext();
    if (shared.state === "suspended") void shared.resume().catch(() => undefined);
  } catch {
    // No Web Audio here: levelling falls back to the element's volume.
  }
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
 * the shared context is running, and only once per element: an element
 * routed into a context that isn't running goes silent (WebKit won't even
 * autoplay it), and moving one that's already playing drops its sound.
 */
function connectGraph(video: HTMLVideoElement): Graph | null {
  const existing = graphs.get(video);
  if (existing) return existing;
  const context = shared;
  if (!context || context.state !== "running") return null;
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
    return graph;
  } catch {
    return null;
  }
}

/**
 * Volume levelling and night mode (PROPOSAL §7.3), in the browser: the
 * measured loudness becomes a gain, and night mode a compressor that lifts
 * dialogue and tames explosions. Nothing is re-encoded.
 *
 * `route` is called by the player as soon as its element exists, before
 * it has any data: the element goes through the graph from its first
 * frame, or — if the shared
 * context isn't running (no gesture yet, or Safari's own HLS, which can't
 * feed Web Audio) — plays as it is for the whole session, and a
 * quieter-than-target file can only be turned down, through the element's
 * volume (volumeScale).
 */
export function useAudioLevelling(
  video: HTMLVideoElement | null,
  loudness: Loudness | null,
  { levelling, night, webAudio }: { levelling: boolean; night: boolean; webAudio: boolean },
): { routed: boolean; route: () => void } {
  const [graph, setGraph] = useState<Graph | null>(null);
  const webAudioRef = useRef(webAudio);
  webAudioRef.current = webAudio;

  const route = useCallback(() => {
    if (!video || !webAudioRef.current) return;
    const nodes = connectGraph(video);
    if (nodes) setGraph(nodes);
  }, [video]);

  // Already routed (the same element, a setting changed): keep using it.
  useEffect(() => {
    const nodes = video ? graphs.get(video) : undefined;
    setGraph(nodes && webAudio ? nodes : null);
  }, [video, webAudio]);

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
