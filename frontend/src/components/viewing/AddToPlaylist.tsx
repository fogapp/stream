import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { ListPlus } from "lucide-react";
import { useAddToPlaylist, type PlaylistItem } from "@/hooks/useAddToPlaylist";
import { playlistsQuery } from "@/lib/queries";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Menu } from "@/components/ui/Menu";

/** Add a movie or episode to one of this profile's playlists, or start one. */
export function AddToPlaylist({
  item,
  className,
  align = "left",
}: {
  item: PlaylistItem;
  className?: string;
  align?: "left" | "right";
}) {
  const [title, setTitle] = useState("");
  const [added, setAdded] = useState<string | null>(null);
  const playlists = useQuery(playlistsQuery());
  const { add, create } = useAddToPlaylist(item, { onAdded: setAdded });

  return (
    <Menu label="Add to playlist" align={align} icon={<ListPlus className="h-4 w-4" aria-hidden />} className={className}>
      <div className="space-y-3">
        {playlists.isPending ? <p className="text-sm text-muted">Loading playlists…</p> : null}
        {playlists.isError ? (
          <div className="flex items-center justify-between gap-2">
            <p className="text-sm text-negative">Couldn't load playlists.</p>
            <Button variant="ghost" size="sm" onClick={() => void playlists.refetch()}>
              Try again
            </Button>
          </div>
        ) : null}
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
            const name = title.trim();
            if (name) create.mutate(name, { onSuccess: () => setTitle("") });
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
