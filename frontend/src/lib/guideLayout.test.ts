import { describe, expect, it } from "vitest";
import { airingAt, chunksCovering, CHUNK, halfHours, mergeGuides, moveFocus, openingTime, xOf, type GuideRow } from "@/lib/guideLayout";
import type { Airing, Guide, GuideStation } from "@/types";

const at = (clock: string) => Date.parse(`2026-09-27T${clock}:00Z`);
const airing = (id: string, from: string, to: string) =>
  ({ id, starts_at: new Date(at(from)).toISOString(), ends_at: new Date(at(to)).toISOString() }) as Airing;
const row = (...airings: Airing[]): GuideRow => ({ station: { id: airings[0]?.id ?? "x" } as GuideStation, airings });

describe("the guide's layout", () => {
  it("places time across at a fixed rate", () => {
    const geometry = { start: at("20:00"), end: at("23:00"), pxPerMinute: 6 };
    expect(xOf(geometry, at("20:30"))).toBe(180);
    expect(halfHours(at("20:10"), at("21:30"))).toEqual([at("20:30"), at("21:00")]);
  });

  it("opens on the half hour before the current one", () => {
    expect(openingTime(at("20:10"))).toBe(at("19:30"));
    expect(openingTime(at("20:45"))).toBe(at("20:00"));
  });

  it("loads in aligned slices", () => {
    const chunks = chunksCovering(at("20:10"), at("23:50"));
    expect(chunks.every((chunk) => chunk % CHUNK === 0)).toBe(true);
    expect(chunks[0]).toBeLessThanOrEqual(at("20:10"));
    expect(chunks.at(-1)! + CHUNK).toBeGreaterThan(at("23:50"));
  });

  it("merges slices into rows, each program once, in order", () => {
    const station = (airings: Airing[]) => ({ id: "s", number: "4", name: "Four", call_sign: null, hidden: false, favorite: false, airings });
    const guides = [
      { stations: [station([airing("b", "20:30", "21:00"), airing("a", "20:00", "20:30")])] },
      { stations: [station([airing("b", "20:30", "21:00"), airing("c", "21:00", "21:30")])] },
    ] as Guide[];
    expect(mergeGuides(guides)[0]?.airings.map((entry) => entry.id)).toEqual(["a", "b", "c"]);
  });

  it("joins a stream's channel across slices into one program", () => {
    const station = (airings: Airing[]) => ({ id: "s", number: "50", name: "Door", call_sign: null, hidden: false, favorite: false, live_stream_id: "x", airings });
    const live = (from: string, to: string) => ({ ...airing("stream-s", from, to), kind: "live_stream" }) as Airing;
    const guides = [{ stations: [station([live("21:00", "24:00")])] }, { stations: [station([live("18:00", "21:00")])] }] as Guide[];
    const joined = mergeGuides(guides)[0]?.airings ?? [];
    expect(joined.map((entry) => [entry.starts_at, entry.ends_at])).toEqual([[new Date(at("18:00")).toISOString(), new Date(at("24:00")).toISOString()]]);
  });

  it("finds what's on at a moment, or the next thing in a gap", () => {
    const list = [airing("a", "20:00", "20:22"), airing("b", "20:30", "21:00")];
    expect(airingAt(list, at("20:10"))?.id).toBe("a");
    expect(airingAt(list, at("20:25"))?.id).toBe("b");
    expect(airingAt(list, at("22:00"))?.id).toBe("b");
  });
});

describe("moving around the guide", () => {
  const rows = [
    row(airing("a1", "20:00", "20:30"), airing("a2", "20:30", "21:00"), airing("a3", "21:00", "22:00")),
    row(airing("b1", "19:00", "21:00"), airing("b2", "21:00", "21:30")),
    row(airing("c1", "20:00", "22:00")),
  ];

  it("goes along a row program by program, not back past the start", () => {
    const start = { row: 0, airingId: "a1", cursor: at("20:10") };
    expect(moveFocus(rows, start, "right", at("20:00"))).toEqual({ row: 0, airingId: "a2", cursor: at("20:30") });
    expect(moveFocus(rows, start, "left", at("20:00"))).toBe(start);
  });

  it("goes between rows keeping to the same moment", () => {
    const focus = { row: 0, airingId: "a3", cursor: at("21:00") };
    expect(moveFocus(rows, focus, "down", at("20:00"))).toEqual({ row: 1, airingId: "b2", cursor: at("21:00") });
    expect(moveFocus(rows, { row: 1, airingId: "b2", cursor: at("21:00") }, "down", at("20:00")).airingId).toBe("c1");
    expect(moveFocus(rows, focus, "up", at("20:00"))).toBe(focus);
    expect(moveFocus(rows, focus, "pageDown", at("20:00")).row).toBe(2);
  });
});

describe("a program in parts", () => {
  it("is one program in the guide, first part to last", async () => {
    const { joinParts } = await import("@/lib/guideLayout");
    const part = (id: string, from: string, to: string, start: number, end: number | null, playable = "p") =>
      ({ ...airing(id, from, to), playable_id: playable, media_start: start, media_end: end }) as Airing;
    const joined = joinParts([part("a", "20:00", "20:05", 0, 300), part("b", "20:07", "20:20", 300, 1080), part("c", "20:22", "20:28", 1080, null), part("d", "20:30", "21:00", 0, null, "q")]);
    expect(joined.map((entry) => [entry.id, entry.ends_at])).toEqual([
      ["a", new Date(at("20:28")).toISOString()],
      ["d", new Date(at("21:00")).toISOString()],
    ]);
  });
});
