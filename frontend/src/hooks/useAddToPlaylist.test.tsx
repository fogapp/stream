import type { ReactNode } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, renderHook, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { api } from "@/api/client";
import { useAddToPlaylist } from "@/hooks/useAddToPlaylist";
import { keys } from "@/lib/queryKeys";
import type { PlaylistCard } from "@/types";

function setup(onAdded = vi.fn()) {
  const client = new QueryClient();
  const invalidate = vi.spyOn(client, "invalidateQueries");
  const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={client}>{children}</QueryClientProvider>;
  const hook = renderHook(() => useAddToPlaylist({ kind: "movie", id: "m1" }, { onAdded }), { wrapper });
  return { hook, invalidate, onAdded };
}

describe("useAddToPlaylist", () => {
  afterEach(() => vi.restoreAllMocks());

  it("adds to a playlist and refreshes the playlists and Watch later", async () => {
    const post = vi.spyOn(api, "post").mockResolvedValue({});
    const { hook, invalidate, onAdded } = setup();
    act(() => hook.result.current.add.mutate({ id: "p1", title: "Friday" } as PlaylistCard));
    await waitFor(() => expect(onAdded).toHaveBeenCalledWith("Friday"));
    expect(post).toHaveBeenCalledWith("/playlists/p1/items", { item_type: "movie", item_id: "m1" });
    expect(invalidate).toHaveBeenCalledWith({ queryKey: keys.playlists.all });
    expect(invalidate).toHaveBeenCalledWith({ queryKey: keys.watchLater.all });
  });

  it("starts a playlist with the item in it", async () => {
    const post = vi.spyOn(api, "post").mockResolvedValue({});
    const { hook, onAdded } = setup();
    act(() => hook.result.current.create.mutate("Rainy day"));
    await waitFor(() => expect(onAdded).toHaveBeenCalledWith("Rainy day"));
    expect(post).toHaveBeenCalledWith("/playlists", { title: "Rainy day", item_type: "movie", item_id: "m1" });
  });

  it("says nothing was added when it wasn't", async () => {
    vi.spyOn(api, "post").mockRejectedValue(new Error("down"));
    const { hook, onAdded } = setup();
    act(() => hook.result.current.add.mutate({ id: "p1", title: "Friday" } as PlaylistCard));
    await waitFor(() => expect(hook.result.current.add.isError).toBe(true));
    expect(onAdded).not.toHaveBeenCalled();
  });
});
