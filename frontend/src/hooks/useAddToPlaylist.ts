import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import type { PlaylistCard } from "@/types";

export type PlaylistItem = { kind: "movie" | "episode" | "video"; id: string };

/**
 * Adding an item to one of this profile's playlists, or starting a new one
 * with it. Either moves the playlists and, since Watch later is a playlist
 * too, Watch later. `onAdded` names the playlist; it runs on the mutation,
 * so it still runs when the menu that asked has closed.
 */
export function useAddToPlaylist(item: PlaylistItem, { onAdded }: { onAdded?: (title: string) => void } = {}) {
  const queryClient = useQueryClient();
  const added = (title: string) => {
    void queryClient.invalidateQueries({ queryKey: keys.playlists.all });
    void queryClient.invalidateQueries({ queryKey: keys.watchLater.all });
    onAdded?.(title);
  };
  const add = useMutation({
    mutationFn: (playlist: PlaylistCard) => api.post(`/playlists/${playlist.id}/items`, { item_type: item.kind, item_id: item.id }),
    onSuccess: (_data, playlist) => added(playlist.title),
  });
  const create = useMutation({
    mutationFn: (title: string) => api.post("/playlists", { title, item_type: item.kind, item_id: item.id }),
    onSuccess: (_data, title) => added(title),
  });
  return { add, create };
}
