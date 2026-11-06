import { describe, expect, it } from "vitest";
import { newBlock } from "@/lib/stationDraft";
import { segmentsOf } from "@/lib/stationClock";

const monday = new Date("2026-09-21T00:00:00Z");

describe("a block on the week's clock", () => {
  it("is a band on each of its days", () => {
    const primetime = newBlock("daypart", 0b0011111, 20 * 60, 23 * 60);
    expect(segmentsOf(primetime, 1, monday).map((segment) => segment.day)).toEqual([0, 1, 2, 3, 4]);
  });

  it("splits at midnight, carrying on into the next day", () => {
    const late = newBlock("daypart", 0b1000000, 23 * 60, 2 * 60);
    expect(segmentsOf(late, 0, monday)).toEqual([
      { index: 0, day: 6, start: 1380, end: 1440, continued: false },
      { index: 0, day: 0, start: 0, end: 120, continued: true },
    ]);
  });

  it("shows a special only on its dates this week", () => {
    const special = { ...newBlock("special", 127, 0, 1440), starts_on: "2026-09-24", ends_on: "2026-09-25" };
    expect(segmentsOf(special, 0, monday).map((segment) => segment.day)).toEqual([3, 4]);
  });
});
