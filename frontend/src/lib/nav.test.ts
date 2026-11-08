import { describe, expect, it } from "vitest";
import { navFor, visibleNav } from "@/lib/nav";

const none = { baseball: false, basketball: false, offline: false };
const keysOf = (entries: { key: string }[]) => entries.map(({ key }) => key);

describe("visibleNav", () => {
  it("offers an admin everything the household has turned on", () => {
    expect(keysOf(visibleNav({ role: "admin" }, { kind: "standard" }, { baseball: true, basketball: true, offline: true }))).toEqual([
      "live", "baseball", "basketball", "subscriptions", "collections", "playlists", "downloads",
      "needs_match", "stats", "playback", "activity", "notifications", "settings",
    ]);
  });

  it("keeps Stats and Playback to admins", () => {
    const member = keysOf(visibleNav({ role: "member" }, { kind: "standard" }, none));
    expect(member).not.toContain("stats");
    expect(member).not.toContain("playback");
    expect(member).toContain("settings");
  });

  it("gives a kid profile the watching, not the running — even an admin's", () => {
    expect(keysOf(visibleNav({ role: "admin" }, { kind: "kid" }, none))).toEqual(["live", "subscriptions", "collections", "playlists", "notifications"]);
  });

  it("leaves out what waits on a feature that's off", () => {
    const shown = keysOf(visibleNav({ role: "member" }, { kind: "standard" }, { baseball: true, basketball: false, offline: false }));
    expect(shown).toContain("baseball");
    expect(shown).not.toContain("basketball");
    expect(shown).not.toContain("downloads");
  });
});

describe("navFor", () => {
  it("names the section a path is under, Home only exactly", () => {
    expect(navFor("/")?.label).toBe("Home");
    expect(navFor("/playlists")?.label).toBe("Playlists");
    expect(navFor("/playback?tab=queue")?.label).toBe("Playback");
    expect(navFor("/notifications")?.label).toBe("Notifications");
    expect(navFor("/movie/1")).toBeUndefined();
  });
});
