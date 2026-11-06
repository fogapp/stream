import { act, renderHook } from "@testing-library/react";
import { beforeEach, describe, expect, it } from "vitest";
import { usePlayQueue } from "@/hooks/usePlayQueue";
import type { NextItem } from "@/types";

const item = (id: string) => ({ id, kind: "video", title: id }) as NextItem;

describe("usePlayQueue", () => {
  beforeEach(() => sessionStorage.clear());

  it("adds to the end, and an item queued again moves there", () => {
    const { result } = renderHook(() => usePlayQueue());
    act(() => result.current.enqueue(item("a")));
    act(() => result.current.enqueue(item("b")));
    act(() => result.current.enqueue(item("a")));
    expect(result.current.queue.map((queued) => queued.id)).toEqual(["b", "a"]);
  });

  it("takes one out", () => {
    const { result } = renderHook(() => usePlayQueue());
    act(() => result.current.keepQueue([item("a"), item("b")]));
    act(() => result.current.dequeue("a"));
    expect(result.current.queue.map((queued) => queued.id)).toEqual(["b"]);
  });

  it("is still there after a reload of the tab", () => {
    const first = renderHook(() => usePlayQueue());
    act(() => first.result.current.enqueue(item("a")));
    first.unmount();
    const { result } = renderHook(() => usePlayQueue());
    expect(result.current.queue.map((queued) => queued.id)).toEqual(["a"]);
  });
});
