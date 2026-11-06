import { QueryClient } from "@tanstack/react-query";
import { describe, expect, it } from "vitest";
import { keys } from "@/lib/queryKeys";
import { refreshWatched } from "@/lib/watched";

describe("refreshWatched", () => {
  it("changes a wall's card where it is and leaves the wall to be fetched next time, but refreshes the rest", () => {
    const client = new QueryClient();
    const wall = keys.movies.list({ library_id: "lib" });
    client.setQueryData(wall, {
      pages: [[{ kind: "movie", id: "heat", watched: false }, { kind: "movie", id: "alien", watched: false }]],
      pageParams: [1],
    });
    client.setQueryData(keys.home.all, { hubs: [] });

    refreshWatched(client, { kind: "movie", id: "heat", watched: true });

    const pages = client.getQueryData<{ pages: { id: string; watched: boolean }[][] }>(wall)?.pages;
    expect(pages?.[0]?.map((card) => card.watched)).toEqual([true, false]);
    expect(client.getQueryState(wall)?.isInvalidated).toBe(true);
    expect(client.getQueryState(keys.home.all)?.isInvalidated).toBe(true);
  });

  it("takes a card off a wall of what's unwatched once it's watched, and leaves the unfiltered wall's in place", () => {
    const client = new QueryClient();
    const unwatched = keys.videos.feed({ library_id: "yt", unwatched: true });
    const all = keys.videos.feed({ library_id: "yt", unwatched: false });
    const cards = () => [{ kind: "video", id: "a", watched: false }, { kind: "video", id: "b", watched: false }];
    client.setQueryData(unwatched, { pages: [cards()], pageParams: [1] });
    client.setQueryData(all, { pages: [cards()], pageParams: [1] });

    refreshWatched(client, { kind: "video", id: "a", watched: true });

    const ids = (key: readonly unknown[]) => client.getQueryData<{ pages: { id: string; watched: boolean }[][] }>(key)?.pages[0];
    expect(ids(unwatched)?.map((card) => card.id)).toEqual(["b"]);
    expect(ids(all)?.map((card) => [card.id, card.watched])).toEqual([["a", true], ["b", false]]);
  });

  it("takes a show off a wall of what's unwatched once it's all watched", () => {
    const client = new QueryClient();
    const wall = keys.shows.list({ library_id: "tv", unwatched: true });
    client.setQueryData(wall, { pages: [[{ kind: "show", id: "s", unwatched_count: 3 }]], pageParams: [1] });

    refreshWatched(client, { kind: "show", id: "s", watched: true });

    expect(client.getQueryData<{ pages: unknown[][] }>(wall)?.pages[0]).toEqual([]);
  });
});
