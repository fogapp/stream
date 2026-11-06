import { describe, expect, it } from "vitest";
import { describeOptimizeResult } from "./optimized";

describe("describeOptimizeResult", () => {
  it("says what changed, then why the rest didn't", () => {
    expect(describeOptimizeResult("optimize", { changed: 14, unchanged: { "already made": 3, "can't be read yet": 1 } })).toBe(
      "Queued 14 · 3 already made · 1 can't be read yet",
    );
    expect(describeOptimizeResult("prioritize", { changed: 0, unchanged: { "not queued": 2 } })).toBe("Nothing changed · 2 not queued");
  });
});
