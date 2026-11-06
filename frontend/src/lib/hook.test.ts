import { describe, expect, it } from "vitest";
import { askedSummary, askLabel, hookFollow, posterAt, seasonStanding } from "@/lib/hook";
import type { HookSeason, HookShow } from "@/types";

const season = (overrides: Partial<HookSeason>): HookSeason => ({
  number: 1, episodes: 8, aired: 8, in_stream: 0, requested: 0, next_air_date: null, ...overrides,
});
const show = {} as HookShow;

describe("seasonStanding", () => {
  it("settles a season Stream has whole, or Hook was already asked for", () => {
    expect(seasonStanding(season({ in_stream: 8 }))).toEqual({ label: "Season 1", hint: "In Stream", settled: true });
    expect(seasonStanding(season({ requested: 8 }))).toEqual({ label: "Season 1", hint: "Requested", settled: true });
  });

  it("says what is missing from a season Stream has part of", () => {
    expect(seasonStanding(season({ in_stream: 3 })).hint).toBe("3 of 8 in Stream");
    expect(seasonStanding(season({ requested: 2 })).hint).toBe("2 of 8 requested");
    expect(seasonStanding(season({})).hint).toBe("8 episodes");
  });

  it("names specials, and a season still to air", () => {
    expect(seasonStanding(season({ number: 0, episodes: 1, aired: 1 }))).toMatchObject({ label: "Specials", hint: "1 episode" });
    expect(seasonStanding(season({ aired: 0, next_air_date: null })).hint).toBe("Not aired yet");
    expect(seasonStanding(season({ aired: 0, next_air_date: "2026-11-06" })).hint).toMatch(/^Airs /);
  });
});

describe("asking", () => {
  it("labels the button by what it asks", () => {
    expect(askLabel([], false)).toBe("Request");
    expect(askLabel([], true)).toBe("Follow");
    expect(askLabel([2], false)).toBe("Request Season 2");
    expect(askLabel([0], true)).toBe("Request Specials and follow");
    expect(askLabel([1, 2], true)).toBe("Request 2 seasons and follow");
  });

  it("follows for new episodes only, or everything", () => {
    expect(hookFollow(false, true)).toBeUndefined();
    expect(hookFollow(true, true)).toBe("future");
    expect(hookFollow(true, false)).toBe("everything");
  });

  it("says what the ask did", () => {
    expect(askedSummary({ created: 9, already: 0, show }, false)).toBe("Hook is looking for 9 episodes.");
    expect(askedSummary({ created: 1, already: 0, show }, true)).toBe("Hook is looking for 1 episode and will keep the show coming.");
    expect(askedSummary({ created: 0, already: 4, show }, false)).toBe("Those episodes were already requested.");
    expect(askedSummary({ created: 0, already: 0, show }, true)).toBe("Hook will keep the show coming.");
  });
});

describe("posterAt", () => {
  it("asks TMDB for a poster the size it is drawn", () => {
    expect(posterAt("https://image.tmdb.org/t/p/w500/abc.jpg")).toBe("https://image.tmdb.org/t/p/w92/abc.jpg");
    expect(posterAt("https://image.tmdb.org/t/p/original/abc.jpg", 154)).toBe("https://image.tmdb.org/t/p/w154/abc.jpg");
    expect(posterAt("https://example.com/p.jpg")).toBe("https://example.com/p.jpg");
    expect(posterAt(null)).toBeNull();
  });
});
