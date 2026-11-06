import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useStallWatch } from "@/components/player/useStallWatch";

const playing = () => ({ paused: false, seeking: false, currentTime: 12 }) as HTMLVideoElement;

describe("useStallWatch", () => {
  beforeEach(() => void vi.useFakeTimers());
  afterEach(() => void vi.useRealTimers());

  it("notes a wait worth noting, when it ends", () => {
    const note = vi.fn();
    const { result } = renderHook(() => useStallWatch(note, vi.fn()));
    const element = playing();
    act(() => result.current.onWaiting(element));
    vi.advanceTimersByTime(2_000);
    act(() => result.current.onPlaying(element));
    expect(note).toHaveBeenCalledWith({ kind: "stall", position: 12, detail: { seconds: 2 } });
  });

  it("gives up on a wait that never ends", () => {
    const fallBack = vi.fn();
    const { result } = renderHook(() => useStallWatch(vi.fn(), fallBack));
    act(() => result.current.onWaiting(playing()));
    vi.advanceTimersByTime(30_000);
    expect(fallBack).toHaveBeenCalledWith({ failureClass: "stalled", cause: "waited 30 s for the stream" });
  });

  it("doesn't take a seek's wait or a pause for a stall", () => {
    const note = vi.fn();
    const fallBack = vi.fn();
    const { result } = renderHook(() => useStallWatch(note, fallBack));
    const seeking = { ...playing(), seeking: true } as HTMLVideoElement;
    act(() => result.current.onWaiting(seeking));
    vi.advanceTimersByTime(30_000);
    act(() => result.current.onPlaying(seeking));
    expect(note).not.toHaveBeenCalled();
    expect(fallBack).not.toHaveBeenCalled();
  });
});
