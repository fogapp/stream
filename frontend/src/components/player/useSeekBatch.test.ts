import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { SEEK_SETTLE_MS } from "@/components/player/timing";
import { useSeekBatch } from "@/components/player/useSeekBatch";

describe("useSeekBatch", () => {
  beforeEach(() => void vi.useFakeTimers());
  afterEach(() => void vi.useRealTimers());

  const setup = () => {
    const element = document.createElement("video");
    const read = () => element;
    const { result, unmount } = renderHook(() => useSeekBatch(read));
    return { element, result, unmount };
  };

  it("sends a quick run of seeks to the last of them, once", () => {
    const { element, result } = setup();
    const moved = vi.fn();
    element.addEventListener("seeking", moved);
    const set = vi.spyOn(element, "currentTime", "set");
    act(() => {
      result.current.seek(10);
      result.current.seek(20);
      result.current.seek(30);
    });
    expect(result.current.position()).toBe(30);
    expect(result.current.seeking()).toBe(true);
    expect(set).not.toHaveBeenCalled();
    act(() => void vi.advanceTimersByTime(SEEK_SETTLE_MS));
    expect(set).toHaveBeenCalledOnce();
    expect(set).toHaveBeenCalledWith(30);
    expect(result.current.seeking()).toBe(false);
  });

  it("lands at once when told to", () => {
    const { element, result } = setup();
    const set = vi.spyOn(element, "currentTime", "set");
    act(() => result.current.seek(12, { now: true }));
    expect(set).toHaveBeenCalledWith(12);
    expect(result.current.seeking()).toBe(false);
  });

  it("drops what hadn't landed when it goes", () => {
    const { element, result, unmount } = setup();
    const set = vi.spyOn(element, "currentTime", "set");
    act(() => result.current.seek(12));
    unmount();
    vi.advanceTimersByTime(SEEK_SETTLE_MS);
    expect(set).not.toHaveBeenCalled();
  });
});
