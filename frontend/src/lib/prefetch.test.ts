import { describe, expect, it } from "vitest";
import { pressedTitle } from "@/lib/prefetch";

function inside(markup: string): Element {
  const host = document.createElement("div");
  host.innerHTML = markup;
  return host.querySelector("[data-target]")!;
}

describe("pressedTitle", () => {
  it("reads a watch link, or a button that says where it goes", () => {
    expect(pressedTitle(inside('<a href="/watch/movie/abc"><img data-target></a>'))).toEqual({ kind: "movie", id: "abc", playlistId: null });
    expect(pressedTitle(inside('<button data-watch="/watch/episode/e1?from=start"><span data-target></span></button>'))).toEqual({
      kind: "episode",
      id: "e1",
      playlistId: null,
    });
    expect(pressedTitle(inside('<a data-target href="/watch/video/v1?playlist=p9"></a>'))).toEqual({ kind: "video", id: "v1", playlistId: "p9" });
  });

  it("leaves a version, a timestamp, or anything else to ask for its own session", () => {
    expect(pressedTitle(inside('<a data-target href="/watch/movie/abc?version=f2"></a>'))).toBeNull();
    expect(pressedTitle(inside('<a data-target href="/watch/episode/e1?t=90"></a>'))).toBeNull();
    expect(pressedTitle(inside('<a data-target href="/movie/abc"></a>'))).toBeNull();
    expect(pressedTitle(inside('<a data-target href="/watch/station/2"></a>'))).toBeNull();
  });
});
