import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { watchForPicture, watchPicture } from "@/components/player/watchdog";

/** An element whose clock runs with the timers, decoding frames only while `decoding`. */
function film() {
  const state = { decoding: true, paused: false, seeking: false, readyState: 4, frames: 0, started: performance.now() };
  const element = {
    get currentTime() {
      return (performance.now() - state.started) / 1000;
    },
    get paused() {
      return state.paused;
    },
    get seeking() {
      return state.seeking;
    },
    get readyState() {
      return state.readyState;
    },
    videoWidth: 640,
    playbackRate: 1,
    getVideoPlaybackQuality: () => {
      if (state.decoding) state.frames += 12;
      return { totalVideoFrames: state.frames };
    },
  } as unknown as HTMLVideoElement;
  return { element, state };
}

describe("watchPicture", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("says nothing while frames keep coming", () => {
    const { element } = film();
    const frozen = vi.fn();
    const stop = watchPicture(element, frozen);
    vi.advanceTimersByTime(60_000);
    expect(frozen).not.toHaveBeenCalled();
    stop();
  });

  it("notices the clock moving with no frame decoded, once, and again only after a rest", () => {
    const { element, state } = film();
    const frozen = vi.fn();
    const stop = watchPicture(element, frozen);
    vi.advanceTimersByTime(5_000);
    state.decoding = false;
    vi.advanceTimersByTime(1_500);
    expect(frozen).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1_500);
    expect(frozen).toHaveBeenCalledTimes(1);
    vi.advanceTimersByTime(10_000);
    expect(frozen).toHaveBeenCalledTimes(1);
    vi.advanceTimersByTime(10_000);
    expect(frozen).toHaveBeenCalledTimes(2);
    stop();
  });

  it("doesn't take a pause, a seek or a wait for data for a frozen picture", () => {
    for (const idle of [{ paused: true }, { seeking: true }, { readyState: 2 }]) {
      const { element, state } = film();
      const frozen = vi.fn();
      const stop = watchPicture(element, frozen);
      Object.assign(state, idle, { decoding: false });
      vi.advanceTimersByTime(30_000);
      expect(frozen).not.toHaveBeenCalled();
      stop();
    }
  });
});

describe("watchForPicture", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("notices sound playing over a picture that never came, once", () => {
    const { element, state } = film();
    Object.assign(element, { videoWidth: 0 });
    state.decoding = false;
    const missing = vi.fn();
    const stop = watchForPicture(element, missing);
    vi.advanceTimersByTime(3_000);
    expect(missing).not.toHaveBeenCalled();
    vi.advanceTimersByTime(2_000);
    expect(missing).toHaveBeenCalledTimes(1);
    vi.advanceTimersByTime(30_000);
    expect(missing).toHaveBeenCalledTimes(1);
    stop();
  });

  it("is satisfied by the first frame, however late", () => {
    const { element } = film();
    const missing = vi.fn();
    const stop = watchForPicture(element, missing);
    vi.advanceTimersByTime(60_000);
    expect(missing).not.toHaveBeenCalled();
    stop();
  });

  it("doesn't count a pause or a wait for data", () => {
    const { element, state } = film();
    Object.assign(element, { videoWidth: 0 });
    Object.assign(state, { decoding: false, readyState: 1 });
    const missing = vi.fn();
    const stop = watchForPicture(element, missing);
    vi.advanceTimersByTime(30_000);
    expect(missing).not.toHaveBeenCalled();
    stop();
  });
});
