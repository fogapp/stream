import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useNavigate, useParams } from "react-router-dom";
import { ArrowDown, ArrowUp, Pencil, Play, X } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { PinToHome } from "@/components/viewing/PinToHome";
import { useFormMutation } from "@/hooks/useFormMutation";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { ProgressBar } from "@/components/ui/ProgressBar";
import { Button } from "@/components/ui/Button";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { FormError, FormFooter } from "@/components/ui/Form";
import { IconButton } from "@/components/ui/IconButton";
import { Input } from "@/components/ui/Input";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import type { EpisodeCard, MovieCard, PlaylistDetail as Playlist, VideoCard } from "@/types";

/** One playlist: play it through, or rearrange it. */
export function PlaylistDetail() {
  const { id = "" } = useParams();
  const playlist = useQuery({ queryKey: keys.playlists.detail(id), queryFn: ({ signal }) => api.get<Playlist>(`/playlists/${id}`, { signal }) });
  return (
    <div className="px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
      <QueryState query={playlist} errorMessage="Could not load this playlist.">
        {(data) => <PlaylistPage playlist={data} />}
      </QueryState>
    </div>
  );
}

function PlaylistPage({ playlist }: { playlist: Playlist }) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [renaming, setRenaming] = useState(false);
  const refresh = () => void queryClient.invalidateQueries({ queryKey: keys.playlists.all });
  const remove = useMutation({
    mutationFn: (item: { kind: string; id: string }) => api.delete(`/playlists/${playlist.id}/items?item_type=${item.kind}&item_id=${item.id}`),
    onSuccess: refresh,
  });
  const reorder = useMutation({ mutationFn: (ids: string[]) => api.put(`/playlists/${playlist.id}/order`, { ids }), onSuccess: refresh });
  const destroy = useMutation({
    mutationFn: () => api.delete(`/playlists/${playlist.id}`),
    onSuccess: () => {
      refresh();
      navigate("/playlists");
    },
  });
  const move = (index: number, by: -1 | 1) => {
    const ids = playlist.items.map((item) => item.id);
    const [moved] = ids.splice(index, 1);
    if (!moved) return;
    ids.splice(index + by, 0, moved);
    reorder.mutate(ids);
  };
  const play = (item: MovieCard | EpisodeCard | VideoCard) => navigate(`/watch/${item.kind}/${item.id}?playlist=${playlist.id}`);

  return (
    <div className="space-y-6">
      <header className="space-y-3">
        {renaming ? (
          <Rename playlist={playlist} onDone={() => setRenaming(false)} />
        ) : (
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="min-w-0 truncate text-2xl font-bold tracking-tight text-foreground sm:text-3xl">{playlist.title}</h1>
            {playlist.watch_later ? null : (
              <IconButton label="Rename playlist" onClick={() => setRenaming(true)}>
                <Pencil className="h-4 w-4" aria-hidden />
              </IconButton>
            )}
          </div>
        )}
        <p className="text-sm text-muted">
          {playlist.item_count} {playlist.item_count === 1 ? "item" : "items"}
          {playlist.from_plex ? " · from Plex" : ""}
        </p>
        <div className="flex flex-wrap items-center gap-2">
          {playlist.items[0] ? (
            <Button size="lg" onClick={() => play(playlist.items[0]!)}>
              <Play className="h-5 w-5 fill-current" aria-hidden />
              Play all
            </Button>
          ) : null}
          <PinToHome kind="playlist" id={playlist.id} pinned={playlist.pinned_to_home} onChange={refresh} />
          {playlist.watch_later ? null : (
            <ConfirmButton size="md" question="Delete this playlist?" onConfirm={() => destroy.mutate()}>
              Delete playlist
            </ConfirmButton>
          )}
        </div>
      </header>

      {playlist.items.length === 0 ? (
        <EmptyState title="Nothing in it yet" description="Add movies and episodes from their pages." />
      ) : (
        <ol className="space-y-2">
          {playlist.items.map((item, index) => {
            const image = item.kind === "episode" ? (item.images.still ?? item.images.thumb ?? item.show?.images.backdrop) : (item.images.backdrop ?? item.images.thumb);
            const heading = item.kind === "episode" ? (item.show?.title ?? item.code) : item.title;
            const detail =
              item.kind === "episode"
                ? [item.code, item.title].filter(Boolean).join(" · ")
                : item.kind === "video"
                  ? item.channel?.title
                  : item.year?.toString();
            return (
              <li key={`${item.kind}-${item.id}`} className="group flex items-center gap-3 rounded-[var(--radius-card)] p-2 hover:bg-surface">
                <span className="w-6 shrink-0 text-right font-mono text-sm tabular-nums text-muted">{index + 1}</span>
                <Link to={`/watch/${item.kind}/${item.id}?playlist=${playlist.id}`} aria-label={`Play ${heading}`} className="relative w-32 shrink-0 sm:w-40">
                  <ArtworkImage image={image} sizes="10rem" className="aspect-video rounded-[var(--radius-control)] ring-1 ring-border" />
                  {item.progress ? <ProgressBar variant="overlay" value={item.progress} className="absolute inset-x-0 bottom-0 overflow-hidden rounded-b-[var(--radius-control)]" /> : null}
                </Link>
                <div className="min-w-0 flex-1">
                  <p className="truncate font-medium text-foreground">{heading}</p>
                  {detail ? <p className="truncate text-xs text-muted">{detail}</p> : null}
                </div>
                <div className="flex shrink-0 gap-1">
                  <IconButton label={`Move ${heading} up`} disabled={index === 0} onClick={() => move(index, -1)}>
                    <ArrowUp className="h-4 w-4" aria-hidden />
                  </IconButton>
                  <IconButton label={`Move ${heading} down`} disabled={index === playlist.items.length - 1} onClick={() => move(index, 1)}>
                    <ArrowDown className="h-4 w-4" aria-hidden />
                  </IconButton>
                  <IconButton label={`Remove ${heading}`} onClick={() => remove.mutate(item)}>
                    <X className="h-4 w-4" aria-hidden />
                  </IconButton>
                </div>
              </li>
            );
          })}
        </ol>
      )}
    </div>
  );
}

function Rename({ playlist, onDone }: { playlist: Playlist; onDone: () => void }) {
  const queryClient = useQueryClient();
  const [title, setTitle] = useState(playlist.title);
  const save = useFormMutation({
    fallback: "Couldn't rename the playlist.",
    mutationFn: () => api.patch<Playlist>(`/playlists/${playlist.id}`, { title }),
    onSuccess: (updated) => {
      queryClient.setQueryData(keys.playlists.detail(playlist.id), updated);
      void queryClient.invalidateQueries({ queryKey: keys.playlists.list() });
      onDone();
    },
  });
  return (
    <form
      className="max-w-md space-y-3"
      onSubmit={(event) => {
        event.preventDefault();
        save.mutate();
      }}
    >
      <Input label="Name" name="playlist-title" value={title} onChange={(event) => setTitle(event.target.value)} required />
      <FormError message={save.errorMessage} />
      <FormFooter label="Save" pending={save.isPending} onCancel={onDone} />
    </form>
  );
}
