import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { ArrowLeft, Clock, ClockCheck, Eye, EyeOff, ListEnd, ListPlus, PictureInPicture2, Play, Tv, UserRound } from "lucide-react";
import { api, apiErrorMessage } from "@/api/client";
import { usePlayback } from "@/hooks/usePlayback";
import { useWatchLater } from "@/hooks/useWatchLater";
import { keys } from "@/lib/queryKeys";
import { refreshWatched } from "@/lib/watched";
import { playlistsQuery } from "@/lib/queries";
import { ActionMenu, ActionMenuItem, ActionMenuSeparator } from "@/components/ui/ActionMenu";
import { toast } from "@/components/ui/Toast";
import { cn } from "@/lib/cn";
import type { ClipCard, EpisodeCard, MovieCard, NextItem, PlaylistCard, ShowCard, VideoCard } from "@/types";

/** Anything a card can show, reduced to what its menu needs. */
export type ActionItem =
  | (Pick<MovieCard, "kind" | "id" | "title" | "watched"> & { images?: MovieCard["images"] })
  | Pick<ShowCard, "kind" | "id" | "title" | "unwatched_count">
  | (Pick<EpisodeCard, "kind" | "id" | "code" | "title" | "watched"> & { show?: { id: string; title: string } | null; images?: EpisodeCard["images"] })
  | (Pick<VideoCard, "kind" | "id" | "title" | "watched"> & { channel?: { id: string; title: string } | null; images?: VideoCard["images"] })
  | Pick<ClipCard, "kind" | "id" | "title" | "watched">;

function itemName(item: ActionItem): string {
  if (item.kind === "episode") return [item.show?.title, item.code].filter(Boolean).join(" ") || (item.title ?? "this episode");
  return item.title;
}

/**
 * The "…" on a card: what can be done to this item, scoped to it — Mark
 * watched on a show marks every episode, on an episode just that one.
 */
export function ItemActions({ item, className }: { item: ActionItem; className?: string }) {
  // Shown on hover or focus where there's a pointer; always on a touch screen.
  return (
    <ActionMenu
      label={`More for ${itemName(item)}`}
      className={cn(
        "opacity-0 group-hover:opacity-100 focus-visible:opacity-100 aria-expanded:opacity-100 [@media(hover:none)]:opacity-100",
        className,
      )}
    >
      {(close) => <ItemActionList item={item} close={close} />}
    </ActionMenu>
  );
}

function ItemActionList({ item, close }: { item: ActionItem; close: () => void }) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { current, enqueue, pip, openPip } = usePlayback();
  const watchLater = useWatchLater();
  const [choosingPlaylist, setChoosingPlaylist] = useState(false);

  const run = (work: Promise<unknown>, done: string, changed?: { kind: string; id: string; watched: boolean }) => {
    close();
    work
      .then(() => {
        refreshWatched(queryClient, changed);
        toast.info(done);
      })
      .catch((error: unknown) => toast.error(apiErrorMessage(error, "That didn't go through.")));
  };
  const name = itemName(item);

  if (choosingPlaylist && item.kind !== "show" && item.kind !== "clip") {
    return <PlaylistChoices item={{ kind: item.kind, id: item.id }} name={name} onBack={() => setChoosingPlaylist(false)} close={close} />;
  }

  const setWatched = (watched: boolean) => {
    const work =
      item.kind === "show"
        ? api.post(`/shows/${item.id}/watched`, { watched })
        : api.post("/watch_states", { playable_type: item.kind, playable_id: item.id, watched });
    run(work, `${name}: marked ${watched ? "watched" : "unwatched"}`, { kind: item.kind, id: item.id, watched });
  };

  const queueable = item.kind === "movie" || item.kind === "episode" || item.kind === "video";
  const saveable = queueable ? { kind: item.kind, id: item.id, title: item.kind === "episode" ? name : item.title } : null;
  const saved = saveable ? watchLater.isSaved(saveable) : false;
  const next: NextItem | null = queueable
    ? {
        kind: item.kind,
        id: item.id,
        code: item.kind === "episode" ? item.code : null,
        title: item.title,
        show_title: item.kind === "episode" ? (item.show?.title ?? null) : item.kind === "video" ? (item.channel?.title ?? null) : null,
        image: (item.kind === "episode" ? (item.images?.still ?? item.images?.thumb) : item.kind === "video" ? item.images?.thumb : item.images?.poster) ?? null,
        playlist_id: null,
      }
    : null;
  const watched = item.kind === "show" ? item.unwatched_count === 0 : item.watched;

  return (
    <>
      {item.kind !== "show" ? (
        <ActionMenuItem icon={<Play className="h-4 w-4" aria-hidden />} onSelect={() => navigate(item.kind === "video" ? `/video/${item.id}` : `/watch/${item.kind}/${item.id}`)}>
          Play
        </ActionMenuItem>
      ) : null}
      {item.kind !== "show" && current && current.id !== item.id && !(pip?.kind === "title" && pip.id === item.id) ? (
        <ActionMenuItem
          icon={<PictureInPicture2 className="h-4 w-4" aria-hidden />}
          onSelect={() => {
            openPip({ kind: "title", playable: item.kind, id: item.id, title: name });
            close();
          }}
        >
          Picture in picture
        </ActionMenuItem>
      ) : null}
      {next && current && current.id !== item.id ? (
        <ActionMenuItem
          icon={<ListEnd className="h-4 w-4" aria-hidden />}
          onSelect={() => {
            enqueue(next);
            toast.info(`${name} plays next`);
            close();
          }}
        >
          Play next
        </ActionMenuItem>
      ) : null}
      <ActionMenuItem
        icon={watched ? <EyeOff className="h-4 w-4" aria-hidden /> : <Eye className="h-4 w-4" aria-hidden />}
        onSelect={() => setWatched(!watched)}
      >
        {watched ? "Mark as unwatched" : "Mark as watched"}
      </ActionMenuItem>
      {saveable ? (
        <ActionMenuItem
          icon={saved ? <ClockCheck className="h-4 w-4" aria-hidden /> : <Clock className="h-4 w-4" aria-hidden />}
          onSelect={() => {
            watchLater.toggle(saveable);
            close();
          }}
        >
          {saved ? "Remove from Watch later" : "Save to Watch later"}
        </ActionMenuItem>
      ) : null}
      {queueable ? (
        <ActionMenuItem icon={<ListPlus className="h-4 w-4" aria-hidden />} onSelect={() => setChoosingPlaylist(true)}>
          Add to playlist…
        </ActionMenuItem>
      ) : null}
      {item.kind === "episode" && item.show ? (
        <>
          <ActionMenuSeparator />
          <ActionMenuItem icon={<Tv className="h-4 w-4" aria-hidden />} onSelect={() => navigate(`/show/${item.show!.id}`)}>
            Go to show
          </ActionMenuItem>
        </>
      ) : null}
      {item.kind === "video" && item.channel ? (
        <>
          <ActionMenuSeparator />
          <ActionMenuItem icon={<UserRound className="h-4 w-4" aria-hidden />} onSelect={() => navigate(`/channel/${item.channel!.id}`)}>
            Go to channel
          </ActionMenuItem>
        </>
      ) : null}
    </>
  );
}

/** The menu's second page: this profile's playlists, fetched when asked for. */
function PlaylistChoices({
  item,
  name,
  onBack,
  close,
}: {
  item: { kind: "movie" | "episode" | "video"; id: string };
  name: string;
  onBack: () => void;
  close: () => void;
}) {
  const queryClient = useQueryClient();
  const playlists = useQuery(playlistsQuery());
  const add = (playlist: PlaylistCard) => {
    close();
    api
      .post(`/playlists/${playlist.id}/items`, { item_type: item.kind, item_id: item.id })
      .then(() => {
        void queryClient.invalidateQueries({ queryKey: keys.playlists.all });
        void queryClient.invalidateQueries({ queryKey: keys.watchLater.all });
        toast.info(`Added ${name} to ${playlist.title}`);
      })
      .catch((error: unknown) => toast.error(apiErrorMessage(error, "That didn't go through.")));
  };
  const choices = playlists.data ?? [];
  return (
    <>
      <ActionMenuItem icon={<ArrowLeft className="h-4 w-4" aria-hidden />} onSelect={onBack} autoFocus>
        Back
      </ActionMenuItem>
      <ActionMenuSeparator label="Add to playlist" />
      {playlists.isPending ? <p className="px-2.5 py-1.5 text-sm text-muted">Loading…</p> : null}
      {playlists.isError ? <p className="px-2.5 py-1.5 text-sm text-negative">Couldn't load playlists.</p> : null}
      {playlists.isSuccess && choices.length === 0 ? <p className="px-2.5 py-1.5 text-sm text-muted">No playlists yet — start one from Playlists.</p> : null}
      <div className="max-h-64 overflow-y-auto">
        {choices.map((playlist) => (
          <ActionMenuItem key={playlist.id} onSelect={() => add(playlist)}>
            {playlist.title}
          </ActionMenuItem>
        ))}
      </div>
    </>
  );
}
