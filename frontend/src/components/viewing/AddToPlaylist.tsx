import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ListPlus } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { playlistsQuery } from "@/lib/queries";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Menu } from "@/components/ui/Menu";
import type { PlaylistCard } from "@/types";

/** Add a movie or episode to one of this profile's playlists, or start one. */
export function AddToPlaylist({
  item,
  className,
  align = "left",
}: {
  item: { kind: "movie" | "episode" | "video"; id: string };
  className?: string;
  align?: "left" | "right";
}) {
  const queryClient = useQueryClient();
  const [title, setTitle] = useState("");
  const [added, setAdded] = useState<string | null>(null);
  const playlists = useQuery(playlistsQuery());
  const done = (name: string) => {
    setAdded(name);
    void queryClient.invalidateQueries({ queryKey: keys.playlists.all });
  };
  const add = useMutation({
    mutationFn: (playlist: PlaylistCard) => api.post(`/playlists/${playlist.id}/items`, { item_type: item.kind, item_id: item.id }),
    onSuccess: (_data, playlist) => done(playlist.title),
  });
  const create = useMutation({
    mutationFn: () => api.post("/playlists", { title: title.trim(), item_type: item.kind, item_id: item.id }),
    onSuccess: () => {
      done(title.trim());
      setTitle("");
    },
  });

  return (
    <Menu label="Add to playlist" align={align} icon={<ListPlus className="h-4 w-4" aria-hidden />} className={className}>
      <div className="space-y-3">
        {(playlists.data ?? []).length > 0 ? (
          <div className="max-h-56 space-y-1 overflow-y-auto">
            {(playlists.data ?? []).map((playlist) => (
              <Button key={playlist.id} variant="ghost" size="sm" className="w-full justify-start" onClick={() => add.mutate(playlist)}>
                {playlist.title}
              </Button>
            ))}
          </div>
        ) : null}
        <form
          className="flex gap-2"
          onSubmit={(event) => {
            event.preventDefault();
            if (title.trim()) create.mutate();
          }}
        >
          <Input aria-label="New playlist" placeholder="New playlist…" value={title} onChange={(event) => setTitle(event.target.value)} />
          <Button type="submit" size="sm" disabled={!title.trim() || create.isPending}>
            Add
          </Button>
        </form>
        {added ? (
          <p role="status" className="text-xs text-muted">
            Added to {added}.
          </p>
        ) : null}
      </div>
    </Menu>
  );
}
