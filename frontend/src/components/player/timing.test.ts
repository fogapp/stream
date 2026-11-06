import { describe, expect, it } from "vitest";
import { isBuffered, islandsFrom, startupDetail, startupLabel } from "@/components/player/timing";

describe("startupDetail", () => {
  it("counts every step from the press", () => {
    const detail = startupDetail({ requestedAt: 1000, answeredAt: 1090 }, { manifest: 1210, init: 1400.4, fragment: 1620 }, 1700);
    expect(detail).toEqual({ ms: 700, session_ms: 90, manifest_ms: 210, init_ms: 400, fragment_ms: 620, frame_ms: 700 });
    expect(startupLabel(detail)).toBe("700 ms: session 90, playlist 210, init 400, first fragment 620");
  });

  it("leaves out steps a file or native HLS doesn't have", () => {
    const detail = startupDetail({ requestedAt: 1000, answeredAt: 1050 }, {}, 1300);
    expect(detail).toEqual({ ms: 300, session_ms: 50, frame_ms: 300 });
    expect(startupLabel(detail)).toBe("300 ms: session 50");
  });
});

describe("isBuffered", () => {
  const ranges = (spans: [number, number][]) =>
    ({ length: spans.length, start: (i: number) => spans[i]![0], end: (i: number) => spans[i]![1] }) as TimeRanges;

  it("finds a position inside any buffered range", () => {
    expect(isBuffered(ranges([[0, 30], [120, 150]]), 130)).toBe(true);
    expect(isBuffered(ranges([[0, 30], [120, 150]]), 60)).toBe(false);
  });
});

describe("islandsFrom", () => {
  const ranges = (spans: [number, number][]) =>
    ({ length: spans.length, start: (i: number) => spans[i]![0], end: (i: number) => spans[i]![1] }) as TimeRanges;

  it("finds what a seek back leaves buffered ahead of it", () => {
    // Seeking to 60, outside everything: the island at 120 is ahead.
    expect(islandsFrom(ranges([[0, 30], [120, 150]]), 60)).toBe(60);
    // Seeking into the first range: the island is past where that range ends.
    expect(islandsFrom(ranges([[0, 30], [120, 150]]), 10)).toBe(30);
  });

  it("finds nothing when all that's buffered ahead is the range being played", () => {
    expect(islandsFrom(ranges([[0, 30], [120, 150]]), 130)).toBeNull();
    expect(islandsFrom(ranges([[0, 30]]), 60)).toBeNull();
    expect(islandsFrom(ranges([]), 60)).toBeNull();
    // A hole too small to be a seek's doing.
    expect(islandsFrom(ranges([[0, 30], [30.1, 150]]), 10)).toBeNull();
  });
});
