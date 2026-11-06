import { describe, expect, it } from "vitest";
import { adjacentStation, clockSkew, gapWait, keepLiveTarget, liveOffset, minutesToTime, onAt, stuckAtEnd, timeToMinutes } from "@/lib/live";
import type { Airing, GuideStation } from "@/types";

const airing = (id: string, starts: string, ends: string) => ({ id, starts_at: starts, ends_at: ends }) as Airing;

describe("live TV arithmetic", () => {
  it("finds where live is inside an airing, clamped to it", () => {
    const show = { starts_at: "2026-09-27T20:00:00Z", ends_at: "2026-09-27T20:30:00Z" };
    expect(liveOffset(show, Date.parse("2026-09-27T20:10:00Z"))).toBe(600);
    expect(liveOffset(show, Date.parse("2026-09-27T19:59:00Z"))).toBe(0);
    expect(liveOffset(show, Date.parse("2026-09-27T21:00:00Z"))).toBe(1800);
  });

  it("keeps a standby channel at live without seeking past what it has buffered", () => {
    const ranges = (spans: [number, number][]) =>
      ({ length: spans.length, start: (i: number) => spans[i]![0], end: (i: number) => spans[i]![1] }) as TimeRanges;
    // Live is inside the buffer: go there.
    expect(keepLiveTarget(ranges([[100, 112]]), 100, 108)).toBe(108);
    // Live has run past it: to the end of the buffer, which then grows on in order.
    expect(keepLiveTarget(ranges([[100, 112]]), 100, 125)).toBe(111.5);
    // Nothing buffered where it is: nothing to stay inside.
    expect(keepLiveTarget(ranges([]), 100, 125)).toBe(125);
    expect(keepLiveTarget(ranges([[0, 10]]), 100, 125)).toBe(125);
  });

  it("calls a program over when its picture sticks near the end, but not a stall partway through", () => {
    // Stuck in its last seconds long enough: over.
    expect(stuckAtEnd({ position: 1795, end: 1800, stuckMs: 6_000, paused: false })).toBe(true);
    // Only just stopped there: a stall the stream may yet get past.
    expect(stuckAtEnd({ position: 1795, end: 1800, stuckMs: 2_000, paused: false })).toBe(false);
    // Stuck well before the end: the stream's business, not the end.
    expect(stuckAtEnd({ position: 1700, end: 1800, stuckMs: 60_000, paused: false })).toBe(false);
    // A browser that paused itself at the very end, without saying it ended.
    expect(stuckAtEnd({ position: 1799.9, end: 1800, stuckMs: 0, paused: true })).toBe(true);
    // Paused by the viewer before the end.
    expect(stuckAtEnd({ position: 1795, end: 1800, stuckMs: 60_000, paused: true })).toBe(false);
    expect(stuckAtEnd({ position: 1795, end: Number.NaN, stuckMs: 60_000, paused: false })).toBe(false);
  });

  it("waits out a gap until the server says the next program starts", () => {
    expect(gapWait("That hasn't started yet", 40)).toBe(40_000);
    expect(gapWait("Nothing's on this channel right now", 600)).toBe(300_000);
    expect(gapWait("Nothing's on this channel right now", null)).toBe(60_000);
    expect(gapWait("Getting this ready to stream. It starts by itself in a moment", 3)).toBeNull();
    expect(gapWait("This channel needs converting, so it isn't tuned ahead", null)).toBeNull();
  });

  it("measures how far this device's clock is from the server's", () => {
    expect(clockSkew("2026-09-27T20:00:05Z", Date.parse("2026-09-27T20:00:00Z"))).toBe(5000);
    expect(clockSkew("nonsense")).toBe(0);
  });

  it("says what's on and what's next, gaps included", () => {
    const station = {
      airings: [airing("a", "2026-09-27T20:00:00Z", "2026-09-27T20:22:00Z"), airing("b", "2026-09-27T20:30:00Z", "2026-09-27T20:52:00Z")],
    } as GuideStation;
    expect(onAt(station, Date.parse("2026-09-27T20:05:00Z"))).toMatchObject({ current: { id: "a" }, next: { id: "b" } });
    expect(onAt(station, Date.parse("2026-09-27T20:25:00Z"))).toMatchObject({ current: null, next: { id: "b" } });
  });

  it("flips through channels in number order, wrapping", () => {
    const stations = [{ number: "2" }, { number: "4" }, { number: "9" }];
    expect(adjacentStation(stations, "4", 1)?.number).toBe("9");
    expect(adjacentStation(stations, "9", 1)?.number).toBe("2");
    expect(adjacentStation(stations, "2", -1)?.number).toBe("9");
  });

  it("turns minutes after midnight into a time and back", () => {
    expect(minutesToTime(1230)).toBe("20:30");
    expect(minutesToTime(1440)).toBe("00:00");
    expect(timeToMinutes("08:05")).toBe(485);
    expect(timeToMinutes("8pm")).toBeNull();
  });
});

describe("the household's day", () => {
  it("finds midnight on the household's clock, not the device's", async () => {
    const { dayStart } = await import("@/lib/live");
    const evening = Date.parse("2026-09-28T00:30:00Z"); // 8:30pm in New York
    expect(new Date(dayStart(evening, "America/New_York")).toISOString()).toBe("2026-09-27T04:00:00.000Z");
    expect(new Date(dayStart(evening, "UTC")).toISOString()).toBe("2026-09-28T00:00:00.000Z");
  });
});
