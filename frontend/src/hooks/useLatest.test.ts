import { renderHook } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { useLatest } from "@/hooks/useLatest";

describe("useLatest", () => {
  it("keeps one ref and holds what was passed last", () => {
    const { result, rerender } = renderHook(({ value }) => useLatest(value), { initialProps: { value: 1 } });
    const first = result.current;
    expect(first.current).toBe(1);
    rerender({ value: 2 });
    expect(result.current).toBe(first);
    expect(first.current).toBe(2);
  });
});
