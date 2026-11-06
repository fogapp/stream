import type { ReactNode } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useSessionEvents, useSessionReporting } from "@/components/player/useSessionReporting";
import { beaconProgress, postEvents, postProgress } from "@/lib/playbackSession";

vi.mock("@/lib/playbackSession", () => ({ beaconProgress: vi.fn(() => true), postEvents: vi.fn(), postProgress: vi.fn(() => Promise.resolve(null)) }));
vi.mock("@/lib/lastWatched", () => ({ captureStill: () => "still" }));

const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={new QueryClient()}>{children}</QueryClientProvider>;

const setup = (playing: boolean, onReport = vi.fn()) => {
  const video = { current: Object.assign(document.createElement("video"), { currentTime: 0 }) };
  const flushEvents = vi.fn();
  const hook = renderHook(() => useSessionReporting({ video, url: "/progress", playing, flushEvents, onReport }), { wrapper });
  return { ...hook, flushEvents, onReport };
};

describe("useSessionEvents", () => {
  afterEach(() => void vi.clearAllMocks());

  it("holds events until they're flushed, and sends each once", () => {
    const { result } = renderHook(() => useSessionEvents("/events"));
    result.current.flushEvents();
    expect(postEvents).not.toHaveBeenCalled();
    result.current.note({ kind: "stall", position: 1 });
    result.current.flushEvents();
    result.current.flushEvents();
    expect(postEvents).toHaveBeenCalledOnce();
    expect(postEvents).toHaveBeenCalledWith("/events", [{ kind: "stall", position: 1 }]);
  });
});

describe("useSessionReporting", () => {
  beforeEach(() => void vi.useFakeTimers());
  afterEach(() => {
    vi.useRealTimers();
    vi.clearAllMocks();
  });

  it("reports every ten seconds while playing, and not while paused", () => {
    const { unmount } = setup(true);
    vi.advanceTimersByTime(20_000);
    expect(postProgress).toHaveBeenCalledTimes(2);
    unmount();
    vi.clearAllMocks();
    setup(false);
    vi.advanceTimersByTime(20_000);
    expect(postProgress).not.toHaveBeenCalled();
  });

  it("leaves with a beacon, as ended, and whatever events are held", () => {
    const { unmount, flushEvents } = setup(false);
    unmount();
    expect(flushEvents).toHaveBeenCalledOnce();
    expect(beaconProgress).toHaveBeenCalledWith("/progress", expect.objectContaining({ ended: true }));
    expect(postProgress).not.toHaveBeenCalled();
  });

  it("says the frame on screen when it's stopping, not on a timed report", () => {
    const onReport = vi.fn();
    const video = { current: Object.assign(document.createElement("video"), { currentTime: 0 }) };
    Object.defineProperty(video.current, "paused", { value: false });
    const { result } = renderHook(() => useSessionReporting({ video, url: "/progress", playing: true, flushEvents: vi.fn(), onReport }), { wrapper });
    act(() => result.current());
    expect(onReport).toHaveBeenLastCalledWith(0, 0, null);
    act(() => result.current(true));
    expect(onReport).toHaveBeenLastCalledWith(0, 0, "still");
  });
});
