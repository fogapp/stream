import { describe, expect, it } from "vitest";
import { arrange, move } from "./sidebar";

const items = ["movies", "tv", "live", "playlists", "settings"].map((key) => ({ key }));
const keysOf = (list: { key: string }[]) => list.map(({ key }) => key);

describe("arrange", () => {
  it("keeps the default order when nothing is placed", () => {
    expect(keysOf(arrange(items, []))).toEqual(["movies", "tv", "live", "playlists", "settings"]);
  });

  it("follows the profile's order and ignores keys that name nothing", () => {
    expect(keysOf(arrange(items, ["settings", "gone", "playlists", "live", "tv", "movies"]))).toEqual([
      "settings",
      "playlists",
      "live",
      "tv",
      "movies",
    ]);
  });

  it("puts an unplaced item after the one it follows by default", () => {
    expect(keysOf(arrange(items, ["live", "movies", "playlists", "settings"]))).toEqual(["live", "movies", "tv", "playlists", "settings"]);
    expect(keysOf(arrange(items, ["tv", "live"]))).toEqual(["movies", "tv", "live", "playlists", "settings"]);
  });
});

describe("move", () => {
  it("swaps with the neighbour, and does nothing past either end", () => {
    expect(move(["a", "b", "c"], "b", -1)).toEqual(["b", "a", "c"]);
    expect(move(["a", "b", "c"], "b", 1)).toEqual(["a", "c", "b"]);
    expect(move(["a", "b", "c"], "a", -1)).toEqual(["a", "b", "c"]);
    expect(move(["a", "b", "c"], "c", 1)).toEqual(["a", "b", "c"]);
  });
});
