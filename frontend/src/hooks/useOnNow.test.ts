import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useOnNow } from "@/hooks/useOnNow";
import type { GuideStation } from "@/types";

const at = (ms: number) => new Date(ms).toISOString();

const station = {
  id: "s1",
  number: "4",
  airings: [
    { id: "a", starts_at: at(0), ends_at: at(60_000) },
    { id: "b", starts_at: at(60_000), ends_at: at(120_000) },
    { id: "c", starts_at: at(180_000), ends_at: at(240_000) },
  ],
} as unknown as GuideStation;

describe("useOnNow", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(10_000);
  });
  afterEach(() => vi.useRealTimers());

  it("moves on at the next airing's start, not a second's tick", () => {
    let renders = 0;
    const { result } = renderHook(() => {
      renders += 1;
      return useOnNow(station, 0);
    });
    expect(result.current.current?.id).toBe("a");
    expect(result.current.next?.id).toBe("b");
    const before = renders;
    act(() => void vi.advanceTimersByTime(49_000));
    // Nothing changed for 49 seconds: nothing rendered.
    expect(renders).toBe(before);
    expect(result.current.current?.id).toBe("a");
    act(() => void vi.advanceTimersByTime(1_001));
    expect(result.current.current?.id).toBe("b");
    expect(result.current.next?.id).toBe("c");
  });

  it("follows a gap: the end of one airing with nothing yet after it", () => {
    vi.setSystemTime(100_000);
    const { result } = renderHook(() => useOnNow(station, 0));
    expect(result.current.current?.id).toBe("b");
    act(() => void vi.advanceTimersByTime(20_001));
    expect(result.current.current).toBeNull();
    expect(result.current.next?.id).toBe("c");
    act(() => void vi.advanceTimersByTime(60_000));
    expect(result.current.current?.id).toBe("c");
  });

  it("reads the server's clock", () => {
    // The server is 55 s ahead: by its clock "b" started 5 s ago.
    const { result } = renderHook(() => useOnNow(station, 55_000));
    expect(result.current.current?.id).toBe("b");
  });
});
