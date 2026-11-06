import { beforeEach, describe, expect, it } from "vitest";
import { livePlace } from "@/lib/livePlace";

const NOW = Date.parse("2026-10-01T22:55:00Z");
const place = { stationId: "five", airingId: "airing-1", position: 1011.8, endsAt: "2026-10-01T23:30:00Z" };

describe("livePlace", () => {
  beforeEach(() => {
    sessionStorage.clear();
    livePlace.leave();
  });

  it("brings a reload back to where the viewer was, behind live, while the program is still on", () => {
    livePlace.watch("five");
    livePlace.save(place);
    expect(livePlace.resume("five", NOW)).toEqual({ airing_id: "airing-1", start: 1011.8 });
    // A reload: the page watches the channel again, and the place is still there.
    livePlace.watch("five");
    expect(livePlace.resume("five", NOW)).toEqual({ airing_id: "airing-1", start: 1011.8 });
    expect(livePlace.resume("five", Date.parse("2026-10-01T23:31:00Z"))).toBeNull();
    expect(livePlace.resume("two", NOW)).toBeNull();
  });

  it("forgets the place at live, on another channel, and on leaving", () => {
    livePlace.watch("five");
    livePlace.save(place);
    livePlace.clear("five");
    expect(livePlace.resume("five", NOW)).toBeNull();

    livePlace.save(place);
    livePlace.watch("two");
    expect(livePlace.resume("five", NOW)).toBeNull();
    // The channel just left reports once more as it goes: not kept.
    livePlace.save(place);
    expect(livePlace.resume("five", NOW)).toBeNull();

    livePlace.watch("five");
    livePlace.save(place);
    livePlace.leave();
    expect(livePlace.resume("five", NOW)).toBeNull();
  });

  it("takes anything else in storage as nothing", () => {
    sessionStorage.setItem("stream_live_place", "{not json");
    expect(livePlace.resume("five", NOW)).toBeNull();
    sessionStorage.setItem("stream_live_place", JSON.stringify({ stationId: "five" }));
    expect(livePlace.resume("five", NOW)).toBeNull();
  });
});
