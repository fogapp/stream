import { act, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { usePlayerVolume } from "@/components/player/usePlayerVolume";
import { rememberMuted, rememberVolume, viewerMuted } from "@/lib/volume";

describe("usePlayerVolume", () => {
  afterEach(() => rememberMuted(false));

  it("sets the element to the chosen volume times the levelling", () => {
    rememberVolume(0.5);
    const element = document.createElement("video");
    renderHook(() => usePlayerVolume({ element, scale: 0.5 }));
    expect(element.volume).toBe(0.25);
    expect(element.muted).toBe(false);
  });

  it("mutes for the next player too, and comes back at the old volume", () => {
    rememberVolume(0.4);
    const element = document.createElement("video");
    const { result } = renderHook(() => usePlayerVolume({ element }));
    act(() => result.current.toggleMute());
    expect(element.muted).toBe(true);
    expect(viewerMuted()).toBe(true);
    act(() => result.current.toggleMute());
    expect(element.muted).toBe(false);
    expect(element.volume).toBe(0.4);
    expect(viewerMuted()).toBe(false);
  });

  it("turned up while silenced, says so; silenced, it's quiet whatever its volume", () => {
    rememberVolume(0.6);
    const element = document.createElement("video");
    const onUnsilence = vi.fn();
    const { result } = renderHook(() => usePlayerVolume({ element, silenced: true, onUnsilence }));
    expect(element.muted).toBe(true);
    act(() => result.current.changeVolume(0));
    expect(onUnsilence).not.toHaveBeenCalled();
    act(() => result.current.changeVolume(0.7));
    expect(onUnsilence).toHaveBeenCalledOnce();
  });

  it("starts as quiet as it's told to", () => {
    const element = document.createElement("video");
    const { result } = renderHook(() => usePlayerVolume({ element, startMuted: () => true }));
    expect(result.current.quiet).toBe(true);
    expect(element.volume).toBe(0);
  });

  it("clamps what it's given", () => {
    rememberVolume(1);
    const element = document.createElement("video");
    const { result } = renderHook(() => usePlayerVolume({ element }));
    act(() => result.current.changeVolume(1.5));
    expect(result.current.volume).toBe(1);
  });
});
