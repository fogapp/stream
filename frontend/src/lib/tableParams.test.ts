import { describe, expect, it } from "vitest";
import { readSort, toSearch } from "./tableParams";

describe("toSearch", () => {
  it("sends arrays Rails-style and leaves empty values off", () => {
    expect(toSearch({ q: "heat", methods: ["remux", "direct"], page: 2, device_id: "", from: null, all: false, every: true })).toBe(
      "?q=heat&methods%5B%5D=remux&methods%5B%5D=direct&page=2&every=true",
    );
    expect(toSearch({ q: undefined })).toBe("");
  });
});

describe("readSort", () => {
  const fallback = { key: "started_at", direction: "desc" } as const;

  it("reads the column and direction, falling back on what it can't use", () => {
    expect(readSort(new URLSearchParams("sort=stalls&dir=asc"), fallback)).toEqual({ key: "stalls", direction: "asc" });
    expect(readSort(new URLSearchParams("sort=stalls&dir=sideways"), fallback)).toEqual({ key: "stalls", direction: "desc" });
    expect(readSort(new URLSearchParams(""), fallback)).toEqual(fallback);
  });
});
