import { describe, expect, it } from "vitest";
import { scalarChips } from "./chips";

describe("scalarChips", () => {
  it("keeps scalars in order and drops blanks and nested values", () => {
    expect(scalarChips({ a: 1, b: null, c: "", d: { x: 1 }, e: true })).toEqual([
      { key: "a", value: "1" },
      { key: "e", value: "true" },
    ]);
  });

  it("folds nested values when asked, and honours skip and max", () => {
    const chips = scalarChips({ id: "s1", a: { x: 1 }, b: 2, c: 3 }, { skip: new Set(["id"]), max: 2, foldObjects: true });
    expect(chips).toEqual([
      { key: "a", value: '{"x":1}' },
      { key: "b", value: "2" },
    ]);
  });
});
