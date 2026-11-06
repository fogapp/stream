import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useNow } from "@/hooks/useNow";

describe("useNow", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(10_000);
  });
  afterEach(() => vi.useRealTimers());

  it("ticks, on the server's clock", () => {
    const { result } = renderHook(() => useNow(1_000, 500));
    expect(result.current).toBe(10_500);
    act(() => void vi.advanceTimersByTime(2_000));
    expect(result.current).toBe(12_500);
  });

  it("holds still without an interval", () => {
    const { result } = renderHook(() => useNow(null));
    act(() => void vi.advanceTimersByTime(5_000));
    expect(result.current).toBe(10_000);
  });
});
