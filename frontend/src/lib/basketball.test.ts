import { describe, expect, it } from "vitest";
import { groupGames, periodLabel, refreshEvery, startTime } from "@/lib/basketball";
import type { BasketballDay, BasketballGame, BasketballGameSide } from "@/types";

function side(club: string): BasketballGameSide {
  return {
    team: { id: club, name: club, club, location: null, abbreviation: club.slice(0, 3).toUpperCase(), logo_url: null, logo_dark_url: null },
    record: null,
    score: null,
    winner: false,
    leader: null,
  };
}

function game(overrides: Partial<BasketballGame> = {}): BasketballGame {
  return {
    id: "1",
    starts_at: "2026-10-21T23:00:00Z",
    start_time_tbd: false,
    state: "upcoming",
    status: "10/21 - 7:00 PM EDT",
    period: 0,
    venue: null,
    preseason: false,
    series: null,
    periods: [],
    scheduled_periods: 4,
    away: side("Hawks"),
    home: side("Pistons"),
    broadcasts: [],
    ...overrides,
  };
}

function day(games: BasketballGame[], date = "2026-10-21"): BasketballDay {
  return { date, today: "2026-10-21", previous_date: null, next_date: null, watch_url: "https://www.nba.com/games?date=2026-10-21", games };
}

describe("periodLabel", () => {
  it("numbers the quarters and counts the overtimes", () => {
    expect([1, 4, 5, 6, 7].map(periodLabel)).toEqual(["1", "4", "OT", "2OT", "3OT"]);
  });
});

describe("startTime", () => {
  it("says TBD when the start isn't set", () => {
    expect(startTime(game({ start_time_tbd: true }))).toBe("TBD");
  });
});

describe("groupGames", () => {
  it("puts live games first and leaves empty groups out", () => {
    const groups = groupGames([game({ id: "a", state: "final" }), game({ id: "b", state: "live" }), game({ id: "c" })]);
    expect(groups.map((group) => group.state)).toEqual(["live", "upcoming", "final"]);
  });
});

describe("refreshEvery", () => {
  it("asks every few seconds while a game is on, now and then today, and never on a settled day", () => {
    expect(refreshEvery(day([game({ state: "live" })]))).toBe(15_000);
    expect(refreshEvery(day([game()]))).toBe(60_000);
    expect(refreshEvery(day([game({ state: "final" })], "2026-10-20"))).toBe(false);
    expect(refreshEvery(undefined)).toBe(false);
  });
});
