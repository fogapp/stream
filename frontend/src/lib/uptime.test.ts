import { describe, expect, it } from "vitest";
import { formatUptime } from "./uptime";

const NOW = new Date("2026-08-27T12:00:00Z");
const ago = (seconds: number) => new Date(NOW.getTime() - seconds * 1000);

describe("formatUptime", () => {
  it("has no unit for a server that just came up", () => {
    expect(formatUptime(ago(5), NOW)).toBe("moments");
  });

  it("counts minutes, then hours with minutes, then days with hours", () => {
    expect(formatUptime(ago(90), NOW)).toBe("1m");
    expect(formatUptime(ago(3 * 3600 + 5 * 60), NOW)).toBe("3h 5m");
    expect(formatUptime(ago(2 * 86400 + 7 * 3600), NOW)).toBe("2d 7h");
  });

  it("never goes negative when the clocks disagree", () => {
    expect(formatUptime(new Date(NOW.getTime() + 60_000), NOW)).toBe("moments");
  });
});
