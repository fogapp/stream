import { describe, expect, it } from "vitest";
import { formatClock, formatRuntime, capturedMonth, formatCaptured } from "@/lib/format";

describe("formatClock", () => {
  it("drops the hours under an hour and pads the rest", () => {
    expect(formatClock(0)).toBe("0:00");
    expect(formatClock(65.9)).toBe("1:05");
    expect(formatClock(3723)).toBe("1:02:03");
  });

  it("never goes negative", () => {
    expect(formatClock(-4)).toBe("0:00");
  });
});

describe("formatRuntime", () => {
  it("reads like a listing", () => {
    expect(formatRuntime(112)).toBe("1h 52m");
    expect(formatRuntime(47)).toBe("47m");
    expect(formatRuntime(null)).toBeNull();
  });
});

describe("formatCaptured", () => {
  it("shows a camera's wall clock as it was, whatever the viewer's zone", () => {
    const clip = { captured_at: "2023-07-14T10:15:00Z", captured_floating: true };
    expect(formatCaptured(clip, { hour: "2-digit", minute: "2-digit", hour12: false })).toBe("10:15");
    expect(capturedMonth(clip)).toEqual({ year: 2023, month: 6 });
  });
});
