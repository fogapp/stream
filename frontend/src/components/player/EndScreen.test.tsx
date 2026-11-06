import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { EndScreen } from "@/components/player/EndScreen";
import { autoplayPick, rememberAutoplay, storedAutoplay, type Offers } from "@/components/player/offers";
import type { VideoCard } from "@/types";

const card = (id: string, watched = false): VideoCard => ({
  kind: "video",
  id,
  title: `Video ${id}`,
  upload_date: null,
  duration_seconds: 60,
  channel: null,
  images: {} as VideoCard["images"],
  progress: null,
  watched,
});

const screenFor = (offers: Offers, props: Partial<Parameters<typeof EndScreen>[0]> = {}) => {
  const onPlay = vi.fn();
  const onPrefetch = vi.fn();
  render(
    <EndScreen
      offers={offers}
      belowBar={false}
      autoplay
      seconds={3}
      stillWatching={false}
      onAutoplay={vi.fn()}
      onPrefetch={onPrefetch}
      onPlay={onPlay}
      onReplay={vi.fn()}
      onClose={vi.fn()}
      {...props}
    />,
  );
  return { onPlay, onPrefetch };
};

describe("autoplayPick", () => {
  it("prefers the first one not yet watched", () => {
    expect(autoplayPick({ next: card("a", true), others: [card("b", true), card("c")] })?.id).toBe("c");
  });

  it("falls back to the channel's own when every one is watched", () => {
    expect(autoplayPick({ next: card("a", true), others: [card("b", true)] })?.id).toBe("a");
    expect(autoplayPick({ next: null, others: [card("b", true)] })?.id).toBe("b");
  });
});

describe("autoplay setting", () => {
  afterEach(() => localStorage.clear());

  it("is off until turned on, and remembered", () => {
    expect(storedAutoplay()).toBe(false);
    rememberAutoplay(true);
    expect(storedAutoplay()).toBe(true);
    rememberAutoplay(false);
    expect(storedAutoplay()).toBe(false);
  });
});

describe("EndScreen autoplay", () => {
  afterEach(() => vi.useRealTimers());

  it("counts down to the unwatched one, warms it, and plays it", () => {
    vi.useFakeTimers();
    const { onPlay, onPrefetch } = screenFor({ next: card("a", true), others: [card("b")] });
    expect(screen.getByRole("timer")).toHaveTextContent("Up next in 3");
    expect(onPrefetch).toHaveBeenCalledWith(expect.objectContaining({ id: "b" }));
    for (let i = 0; i < 3; i++) act(() => vi.advanceTimersByTime(1000));
    expect(onPlay).toHaveBeenCalledWith(expect.objectContaining({ id: "b" }), true);
  });

  it("doesn't count down when off, or when it's time to ask", () => {
    vi.useFakeTimers();
    const off = screenFor({ next: card("a"), others: [] }, { autoplay: false });
    act(() => vi.advanceTimersByTime(10_000));
    expect(off.onPlay).not.toHaveBeenCalled();
    expect(screen.queryByRole("timer")).toBeNull();
  });

  it("asks instead after a run of them", () => {
    vi.useFakeTimers();
    const { onPlay } = screenFor({ next: card("a"), others: [] }, { stillWatching: true });
    act(() => vi.advanceTimersByTime(10_000));
    expect(onPlay).not.toHaveBeenCalled();
    expect(screen.getByText("Still watching?")).toBeInTheDocument();
  });

  it("switches with the toggle", () => {
    const onAutoplay = vi.fn();
    screenFor({ next: card("a"), others: [] }, { autoplay: false, onAutoplay });
    fireEvent.click(screen.getByRole("checkbox", { name: "Autoplay" }));
    expect(onAutoplay).toHaveBeenCalledWith(true);
  });

  it("a chosen one plays as chosen, not automatic", () => {
    const { onPlay } = screenFor({ next: card("a"), others: [card("b")] }, { autoplay: false });
    fireEvent.click(screen.getByRole("button", { name: /Video b/ }));
    expect(onPlay).toHaveBeenCalledWith(expect.objectContaining({ id: "b" }), false);
  });
});
