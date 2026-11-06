import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { isResyncSeek, keepInSync, levellingGain, needsAudioGraph, soundLabel, volumeScale } from "@/components/player/audio";

describe("levellingGain", () => {
  it("brings a quiet film up and a loud video down to -20 LUFS", () => {
    expect(levellingGain({ integrated: -26, true_peak: -10 })).toBeCloseTo(6);
    expect(levellingGain({ integrated: -12, true_peak: -1 })).toBeCloseTo(-8);
  });

  it("never pushes a peak past -1 dBTP, nor boosts more than 9 dB", () => {
    expect(levellingGain({ integrated: -26, true_peak: -3 })).toBeCloseTo(2);
    expect(levellingGain({ integrated: -40, true_peak: -30 })).toBeCloseTo(9);
  });

  it("leaves an unmeasured file alone", () => {
    expect(levellingGain(null)).toBe(0);
  });
});

describe("volumeScale", () => {
  it("can only turn a loud file down without Web Audio", () => {
    expect(volumeScale({ integrated: -14, true_peak: -1 }, true, false)).toBeCloseTo(0.5, 1);
    expect(volumeScale({ integrated: -30, true_peak: -10 }, true, false)).toBe(1);
    expect(volumeScale({ integrated: -14, true_peak: -1 }, true, true)).toBe(1);
    expect(volumeScale({ integrated: -14, true_peak: -1 }, false, false)).toBe(1);
  });
});

describe("needsAudioGraph", () => {
  const loud = { integrated: -14, true_peak: -1 };
  const quiet = { integrated: -26, true_peak: -10 };

  it("leaves a loud file on the element: turning it down is its volume", () => {
    expect(needsAudioGraph(loud, { levelling: true, night: false })).toBe(false);
    expect(needsAudioGraph(null, { levelling: true, night: false })).toBe(false);
  });

  it("routes for a boost worth having, or for night mode", () => {
    expect(needsAudioGraph(quiet, { levelling: true, night: false })).toBe(true);
    expect(needsAudioGraph({ integrated: -20.5, true_peak: -5 }, { levelling: true, night: false })).toBe(false);
    expect(needsAudioGraph(quiet, { levelling: false, night: false })).toBe(false);
    expect(needsAudioGraph(loud, { levelling: false, night: true })).toBe(true);
  });
});

describe("soundLabel", () => {
  const sound = { levelling: true, night: false, sampleRate: 44_100, resyncs: 2 };

  it("says the element's own volume when the sound isn't routed", () => {
    expect(soundLabel(sound, null, { integrated: -14, true_peak: -1 })).toBe("Element, volume -6.0 dB · 44.1 kHz");
    expect(soundLabel({ ...sound, levelling: false, sampleRate: null }, null, null)).toBe("Element, as it is");
  });

  it("says the graph's rate, latency and resyncs when it is", () => {
    const graph = { sampleRate: 48_000, baseLatency: 0.01, outputLatency: 0.04, state: "running" as const };
    expect(soundLabel({ ...sound, night: true }, graph, { integrated: -26, true_peak: -10 })).toBe(
      "Web Audio (night mode, +6.0 dB) · 48 kHz from 44.1 kHz · latency 10 ms + 40 ms · resynced 2×",
    );
  });
});

describe("keepInSync", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  function setup() {
    const element = document.createElement("video");
    const state = { paused: true, seeking: false, time: 10 };
    const seeks: number[] = [];
    Object.defineProperties(element, {
      paused: { get: () => state.paused },
      seeking: { get: () => state.seeking },
      readyState: { get: () => 4 },
      currentTime: {
        get: () => state.time,
        set: (value: number) => {
          seeks.push(value);
          element.dispatchEvent(new Event("seeking"));
          element.dispatchEvent(new Event("seeked"));
        },
      },
    });
    const context = { state: "running", suspend: vi.fn(() => Promise.resolve()), resume: vi.fn(() => Promise.resolve()) } as unknown as AudioContext;
    const onResync = vi.fn();
    const stop = keepInSync(element, context, onResync);
    const fire = (name: string) => element.dispatchEvent(new Event(name));
    const play = () => {
      state.paused = false;
      fire("play");
      fire("playing");
    };
    return { element, state, seeks, context, onResync, stop, fire, play };
  }

  it("leaves the first start alone", () => {
    const { seeks, play } = setup();
    play();
    vi.advanceTimersByTime(1_000);
    expect(seeks).toEqual([]);
  });

  it("lines the sound up again once playing resumes after a pause, and rests the context meanwhile", () => {
    const { element, state, seeks, context, onResync, fire, play } = setup();
    play();
    state.paused = true;
    fire("pause");
    expect(context.suspend).toHaveBeenCalled();
    play();
    expect(context.resume).not.toHaveBeenCalled(); // still "running" in this fake
    vi.advanceTimersByTime(300);
    expect(seeks).toEqual([10]);
    expect(onResync).toHaveBeenCalledTimes(1);
    expect(isResyncSeek(element)).toBe(false);
    // The resync's own seek isn't another restart.
    fire("playing");
    vi.advanceTimersByTime(1_000);
    expect(seeks).toEqual([10]);
  });

  it("lines it up after a viewer's seek, once, and not while still seeking", () => {
    const { state, seeks, fire, play } = setup();
    play();
    state.seeking = true;
    fire("seeking");
    fire("playing");
    vi.advanceTimersByTime(300);
    expect(seeks).toEqual([]);
    state.seeking = false;
    fire("seeked");
    fire("playing");
    vi.advanceTimersByTime(300);
    expect(seeks).toEqual([10]);
  });

  it("starts over with another source, and stops listening when told", () => {
    const { state, seeks, fire, play, stop } = setup();
    play();
    fire("emptied");
    play();
    vi.advanceTimersByTime(300);
    expect(seeks).toEqual([]);
    stop();
    state.paused = true;
    fire("pause");
    play();
    vi.advanceTimersByTime(300);
    expect(seeks).toEqual([]);
  });
});
