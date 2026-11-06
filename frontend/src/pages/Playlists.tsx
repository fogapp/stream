import { useQuery } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { ListVideo } from "lucide-react";
import { playlistsQuery } from "@/lib/queries";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { PageHeader } from "@/components/layout/PageHeader";
import { EmptyState, QueryState } from "@/components/ui/PageState";

/** This profile's playlists (PROPOSAL §7.4). */
export function Playlists() {
  const playlists = useQuery(playlistsQuery());
  return (
    <div className="space-y-6 px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
      <PageHeader title="Playlists" description="Movies and episodes to play in order. Each profile keeps its own." />
      <QueryState query={playlists} errorMessage="Could not load playlists.">
        {(list) =>
          list.length === 0 ? (
            <EmptyState title="No playlists yet" description="Start one from any movie or episode: Add to playlist." />
          ) : (
            <div className="grid grid-cols-1 gap-x-3 gap-y-5 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
              {list.map((playlist) => (
                <Link key={playlist.id} to={`/playlist/${playlist.id}`} className="group block min-w-0">
                  <ArtworkImage
                    image={playlist.image}
                    sizes="(min-width: 1280px) 20rem, (min-width: 640px) 45vw, 90vw"
                    className="aspect-video rounded-[var(--radius-card)] ring-1 ring-border transition group-hover:ring-2 group-hover:ring-primary"
                    fallback={<ListVideo className="h-8 w-8 text-muted" aria-hidden />}
                  />
                  <p className="mt-2 truncate text-sm font-medium text-foreground">{playlist.title}</p>
                  <p className="text-xs text-muted">
                    {playlist.item_count} {playlist.item_count === 1 ? "item" : "items"}
                    {playlist.from_plex ? " · from Plex" : ""}
                  </p>
                </Link>
              ))}
            </div>
          )
        }
      </QueryState>
    </div>
  );
}
