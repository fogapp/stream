import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { clearLastWatched, loadLastWatched, saveLastWatched, type LastWatched } from "@/lib/lastWatched";

const record: LastWatched = {
  kind: "episode",
  id: "e1",
  title: "Pilot",
  subtitle: "S1 · E1",
  playlistId: null,
  mediaFileId: "f1",
  position: 312,
  duration: 2600,
  still: "data:image/jpeg;base64,AAAA",
};

describe("what was last watched", () => {
  // A Map-backed store: Node's own localStorage can shadow jsdom's.
  beforeEach(() => {
    const items = new Map<string, string>();
    vi.stubGlobal("localStorage", {
      getItem: (key: string) => items.get(key) ?? null,
      setItem: (key: string, value: string) => void items.set(key, value),
      removeItem: (key: string) => void items.delete(key),
    });
  });
  afterEach(() => vi.unstubAllGlobals());

  it("comes back after a reload, per profile", () => {
    saveLastWatched("p1", record);
    expect(loadLastWatched("p1")).toEqual(record);
    expect(loadLastWatched("p2")).toBeNull();
  });

  it("is forgotten when cleared", () => {
    saveLastWatched("p1", record);
    clearLastWatched("p1");
    expect(loadLastWatched("p1")).toBeNull();
  });

  it("ignores what it can't trust", () => {
    localStorage.setItem("stream_last_watched:p1", JSON.stringify({ ...record, kind: "song" }));
    expect(loadLastWatched("p1")).toBeNull();
    localStorage.setItem("stream_last_watched:p1", JSON.stringify({ ...record, still: "javascript:alert(1)" }));
    expect(loadLastWatched("p1")?.still).toBeNull();
    localStorage.setItem("stream_last_watched:p1", "{not json");
    expect(loadLastWatched("p1")).toBeNull();
  });
});
