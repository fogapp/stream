import { describe, expect, it } from "vitest";
import { formatMillis } from "./numbers";

describe("formatMillis", () => {
  it("picks the unit by magnitude", () => {
    expect(formatMillis(842)).toBe("842ms");
    expect(formatMillis(1234)).toBe("1.2s");
    expect(formatMillis(184_000)).toBe("3m 04s");
  });
});
