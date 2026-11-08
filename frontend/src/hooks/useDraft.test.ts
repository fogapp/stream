import { act, renderHook } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { useDraft } from "@/hooks/useDraft";

type Fields = { url: string; model: string; api_key: string };
const defaults: Fields = { url: "", model: "", api_key: "" };

describe("useDraft", () => {
  it("starts from the server's values, falling back to the defaults for what's unset", () => {
    const { result } = renderHook(() => useDraft<Fields>({ url: "http://whisper:9000", model: null }, defaults));
    expect(result.current.value("url")).toBe("http://whisper:9000");
    expect(result.current.value("model")).toBe("");
    expect(result.current.value("api_key")).toBe("");
    expect(result.current.dirty).toBe(false);
  });

  it("uses the defaults while nothing is stored", () => {
    const { result } = renderHook(() => useDraft<Fields>(null, { ...defaults, model: "whisper-1" }));
    expect(result.current.values()).toEqual({ url: "", model: "whisper-1", api_key: "" });
  });

  it("keeps an edit over a refetch, even an edit to empty", () => {
    const { result, rerender } = renderHook(({ url }) => useDraft<Fields>({ url }, defaults), { initialProps: { url: "http://a" } });
    act(() => result.current.set("url", ""));
    rerender({ url: "http://b" });
    expect(result.current.value("url")).toBe("");
    expect(result.current.dirty).toBe(true);
    expect(result.current.values()).toEqual({ url: "", model: "", api_key: "" });
  });

  it("goes back to the server's values on reset", () => {
    const { result, rerender } = renderHook(({ url }) => useDraft<Fields>({ url }, defaults), { initialProps: { url: "http://a" } });
    act(() => result.current.set("url", "http://typed"));
    rerender({ url: "http://saved" });
    act(() => result.current.reset());
    expect(result.current.value("url")).toBe("http://saved");
    expect(result.current.dirty).toBe(false);
  });
});
