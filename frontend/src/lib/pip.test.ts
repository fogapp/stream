import { describe, expect, it } from "vitest";
import { handoffKey, heardToo, hears, livePath, sameSource } from "@/lib/pip";

describe("pip sound", () => {
  it("hears the place chosen, or both", () => {
    expect(hears("main", "main")).toBe(true);
    expect(hears("main", "pip")).toBe(false);
    expect(hears("both", "pip")).toBe(true);
    expect(hears("pip", "main")).toBe(false);
  });

  it("unmuting a silenced picture makes it both", () => {
    expect(heardToo("main", "pip")).toBe("both");
    expect(heardToo("pip", "main")).toBe("both");
    expect(heardToo("main", "main")).toBe("main");
  });
});

describe("pip sources", () => {
  const camera = { kind: "stream", id: "c1", title: "Front door" } as const;
  const channel = { kind: "station", stationId: "s1", number: "4.1", title: "Pattern TV" } as const;

  it("compares by what plays, not by title", () => {
    expect(sameSource(camera, { ...camera, title: "Renamed" })).toBe(true);
    expect(sameSource(camera, channel)).toBe(false);
    expect(sameSource({ kind: "title", playable: "movie", id: "1", title: "" }, { kind: "title", playable: "episode", id: "1", title: "" })).toBe(false);
    expect(sameSource(null, camera)).toBe(false);
  });

  it("hands a stream over under its own key, apart from a channel's", () => {
    expect(handoffKey(channel)).toBe("s1");
    expect(handoffKey(camera)).toBe("stream:c1");
  });

  it("goes to the source's own page", () => {
    expect(livePath(channel)).toBe("/live/4.1");
    expect(livePath(camera)).toBe("/stream/c1");
  });
});
