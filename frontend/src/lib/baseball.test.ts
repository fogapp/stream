import { describe, expect, it } from "vitest";
import { dayLabel, finalLabel, groupGames, inningLabel, refreshEvery, watchChoices } from "@/lib/baseball";
import type { BaseballDay, BaseballGame, BaseballGameSide } from "@/types";

function side(club: string, id: number): BaseballGameSide {
  return {
    team: { id, name: club, club, location: club, abbreviation: club.slice(0, 3).toUpperCase(), logo_url: "", logo_png_url: "" },
    record: null,
    score: null,
    hits: null,
    errors: null,
    winner: false,
    probable_pitcher: null,
  };
}

function game(overrides: Partial<BaseballGame> = {}): BaseballGame {
  return {
    id: 1,
    starts_at: "2026-10-20T00:08:00Z",
    start_time_tbd: false,
    state: "upcoming",
    status: "Scheduled",
    watchable: false,
    venue: null,
    series: null,
    double_header: null,
    inning: null,
    innings: [],
    scheduled_innings: 9,
    away: side("Guardians", 114),
    home: side("Rays", 139),
    broadcasts: [],
    decisions: null,
    ...overrides,
  };
}

describe("baseball", () => {
  it("names days around MLB's today", () => {
    expect(dayLabel("2026-10-18", "2026-10-18")).toBe("Today");
    expect(dayLabel("2026-10-17", "2026-10-18")).toBe("Yesterday");
    expect(dayLabel("2026-10-19", "2026-10-18")).toBe("Tomorrow");
    expect(dayLabel("2026-10-25", "2026-10-18")).not.toMatch(/Today|Tomorrow/);
  });

  it("says where in the game it is", () => {
    expect(inningLabel({ number: 7, ordinal: "7th", half: "top", outs: 0, balls: 0, strikes: 0, bases: { first: false, second: false, third: false } })).toBe("Top 7th");
    expect(inningLabel({ number: 9, ordinal: "9th", half: "middle", outs: 3, balls: 0, strikes: 0, bases: { first: false, second: false, third: false } })).toBe("Mid 9th");
    const innings = Array.from({ length: 10 }, (_, index) => ({ number: index + 1, away: 0, home: 0 }));
    expect(finalLabel(game({ innings }))).toBe("Final/10");
    expect(finalLabel(game({ innings: innings.slice(0, 9) }))).toBe("Final");
  });

  it("offers each team's broadcast, or a national one once", () => {
    expect(
      watchChoices(game({ broadcasts: [{ name: "SNY", side: "home" }, { name: "NBCSP", side: "away" }, { name: "MLBN", side: "national" }] })),
    ).toEqual([
      { side: "away", team: "Guardians", channel: "NBCSP" },
      { side: "home", team: "Rays", channel: "SNY" },
    ]);
    expect(watchChoices(game({ broadcasts: [{ name: "TBS", side: "national" }] }))).toEqual([{ side: "home", team: null, channel: "TBS" }]);
    expect(watchChoices(game())).toEqual([{ side: "home", team: null, channel: null }]);
  });

  it("groups live games first and leaves out empty groups", () => {
    const groups = groupGames([game({ id: 1, state: "final" }), game({ id: 2, state: "live" }), game({ id: 3, state: "final" })]);
    expect(groups.map((group) => [group.state, group.games.map((each) => each.id)])).toEqual([
      ["live", [2]],
      ["final", [1, 3]],
    ]);
  });

  it("asks again often only while something is on", () => {
    const day = (games: BaseballGame[], date = "2026-10-18"): BaseballDay => ({ date, today: "2026-10-18", previous_date: null, next_date: null, games });
    expect(refreshEvery(day([game({ state: "live" })]))).toBe(15_000);
    expect(refreshEvery(day([game()]))).toBe(60_000);
    expect(refreshEvery(day([game({ state: "final" })], "2026-10-12"))).toBe(false);
  });
});
