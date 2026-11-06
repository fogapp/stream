import { describe, expect, it } from "vitest";
import { shuffled } from "./shuffle";

describe("shuffled", () => {
  it("keeps every item and leaves the original alone", () => {
    const items = [1, 2, 3, 4, 5];
    const result = shuffled(items);
    expect([...result].sort()).toEqual(items);
    expect(items).toEqual([1, 2, 3, 4, 5]);
  });

  it("moves items by the random source", () => {
    // Always the lowest index: each item swaps with the first.
    expect(shuffled([1, 2, 3, 4], () => 0)).toEqual([2, 3, 4, 1]);
  });
});
