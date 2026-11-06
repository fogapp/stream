import { useState, type ReactNode } from "react";
import { useInfiniteQuery, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useSearchParams } from "react-router-dom";
import { CheckCheck, ChevronRight, LayoutGrid, Plus, Search, UserRound } from "lucide-react";
import { api, apiErrorMessage } from "@/api/client";
import { useAuth } from "@/hooks/useAuth";
import { keys } from "@/lib/queryKeys";
import { cn } from "@/lib/cn";
import { refreshWatched } from "@/lib/watched";
import { AddFromYoutube } from "@/components/youtube/AddFromYoutube";
import { ChannelActions } from "@/components/youtube/ChannelActions";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { VideoTile } from "@/components/viewing/VideoTile";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { LoadMore } from "@/components/ui/LoadMore";
import { EmptyState, ErrorState, LoadingState } from "@/components/ui/PageState";
import { Segmented } from "@/components/ui/Segmented";
import { toast } from "@/components/ui/Toast";
import { VIDEO_GRID } from "@/pages/ChannelDetail";
import type { ChannelListItem, Library, VideoCard } from "@/types";

const PAGE = 60;
const FILTERS = [
  { key: "all", label: "All" },
  { key: "unwatched", label: "Unwatched" },
] as const;

/** Case- and accent-blind, the way the server's `unaccent(...) ILIKE` searches. */
const fold = (text: string) => text.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();

/**
 * A channels library (PROPOSAL §5.4): its channels down the left, and a
 * feed of their videos, newest first, on the right. Picking a channel
 * narrows the feed to it; "All channels" is everything. The feed opens on
 * what's unwatched; All is the one the URL has to ask for. Both live in the URL.
 */
export function ChannelLibrary({ library }: { library: Library }) {
  const { user } = useAuth();
  const [params, setParams] = useSearchParams();
  const selectedId = params.get("channel");
  const unwatched = params.get("filter") !== "all";
  const [adding, setAdding] = useState(false);
  const [query, setQuery] = useState("");
  const [marking, setMarking] = useState(false);
  const queryClient = useQueryClient();

  const channels = useQuery({
    queryKey: keys.channels.list({ library_id: library.id }),
    queryFn: ({ signal }) => api.get<ChannelListItem[]>(`/channels?library_id=${library.id}`, { signal }),
  });
  const list = channels.data ?? [];
  const selected = list.find((channel) => channel.id === selectedId) ?? null;
  const shown = query.trim() ? list.filter((channel) => fold(channel.title).includes(fold(query.trim()))) : list;

  const link = (channelId: string | null) => {
    const next = new URLSearchParams(params);
    if (channelId) next.set("channel", channelId);
    else next.delete("channel");
    return { search: next.toString() };
  };
  // A hidden channel leaves the list; if it was the one picked, so does the pick.
  const dropSelection = (channelId: string) => {
    if (channelId !== selectedId) return;
    const next = new URLSearchParams(params);
    next.delete("channel");
    setParams(next, { replace: true });
  };
  const setFilter = (key: string) => {
    const next = new URLSearchParams(params);
    if (key === "all") next.set("filter", key);
    else next.delete("filter");
    setParams(next, { replace: true });
  };

  // What's in the feed right now: the picked channel, or every channel.
  const unwatchedCount = selected ? selected.unwatched_count : list.reduce((sum, channel) => sum + channel.unwatched_count, 0);
  const markAllWatched = () => {
    setMarking(true);
    api
      .post("/videos/watched", { library_id: library.id, channel_id: selected?.id })
      .then(() => {
        refreshWatched(queryClient);
        // The feed on screen is a wall refreshWatched leaves alone: every card on it may have changed.
        void queryClient.invalidateQueries({ queryKey: keys.videos.all });
        toast.info(`${selected ? selected.title : library.name}: every video marked watched`);
      })
      .catch((error: unknown) => toast.error(apiErrorMessage(error, "That didn't go through.")))
      .finally(() => setMarking(false));
  };

  return (
    <div className="space-y-6 px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <h1 className="text-2xl font-bold text-foreground">{library.name}</h1>
        {user?.role === "admin" && !adding ? (
          <Button onClick={() => setAdding(true)}>
            <Plus className="h-4 w-4" aria-hidden />
            Add from YouTube
          </Button>
        ) : null}
      </div>
      {adding ? <AddFromYoutube onDone={() => setAdding(false)} /> : null}

      {channels.isPending ? (
        <LoadingState />
      ) : channels.isError ? (
        <ErrorState message="Could not load channels." onRetry={() => void channels.refetch()} />
      ) : list.length === 0 ? (
        <EmptyState title="No channels yet" description="Videos show up as soon as they're read, a channel per folder." />
      ) : (
        <div className="flex flex-col gap-6 lg:flex-row lg:items-start">
          <aside aria-label="Channels" className="lg:sticky lg:top-6 lg:w-64 lg:shrink-0">
            <div className="mb-2">
              <Input
                aria-label={`Search ${library.name} channels`}
                placeholder="Search channels"
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                icon={<Search className="h-4 w-4" aria-hidden />}
              />
            </div>
            {/* A row to swipe on a phone; a column that scrolls by itself on a desktop. */}
            <ul className="scrollbar-none -mx-4 flex gap-1 overflow-x-auto px-4 sm:-mx-6 sm:px-6 lg:mx-0 lg:max-h-[calc(100dvh-8rem)] lg:flex-col lg:gap-0.5 lg:overflow-y-auto lg:px-0">
              <li className="shrink-0">
                <ChannelLink to={link(null)} current={!selected} label="All channels" count={list.reduce((sum, channel) => sum + channel.unwatched_count, 0)}>
                  <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-surface-raised ring-1 ring-border">
                    <LayoutGrid className="h-3.5 w-3.5 text-muted" aria-hidden />
                  </span>
                </ChannelLink>
              </li>
              {shown.map((channel) => (
                <li key={channel.id} className="group relative shrink-0">
                  <ChannelLink to={link(channel.id)} current={channel.id === selected?.id} label={channel.title} count={channel.unwatched_count} hasActions>
                    <ArtworkImage
                      image={channel.avatar}
                      sizes="2rem"
                      className="h-7 w-7 shrink-0 rounded-full ring-1 ring-border"
                      fallback={<UserRound className="h-3.5 w-3.5 text-muted" aria-hidden />}
                    />
                  </ChannelLink>
                  {/* In the desktop column, over the count on hover; on a phone the picked channel's header has it. */}
                  <ChannelActions
                    channel={channel}
                    onHidden={() => dropSelection(channel.id)}
                    className={cn(
                      "absolute right-1.5 top-1/2 hidden h-6 w-6 -translate-y-1/2 bg-transparent text-muted hover:text-foreground lg:inline-flex",
                      "opacity-0 group-focus-within:opacity-100 group-hover:opacity-100 aria-expanded:opacity-100 [@media(hover:none)]:opacity-100",
                    )}
                  />
                </li>
              ))}
            </ul>
            {shown.length === 0 ? <p className="px-3 py-2 text-sm text-muted">No channel matches.</p> : null}
          </aside>

          <section aria-label={selected ? selected.title : "All channels"} className="min-w-0 flex-1 space-y-5">
            <div className="flex flex-wrap items-center gap-3">
              {/* Its own line on a phone, so the controls don't squeeze the name. */}
              <div className="min-w-0 flex-1 basis-full sm:basis-0">
                <h2 className="truncate text-lg font-semibold text-foreground">{selected ? selected.title : "All channels"}</h2>
                {selected ? (
                  <p className="text-sm text-muted">
                    {[
                      selected.handle,
                      `${selected.video_count} ${selected.video_count === 1 ? "video" : "videos"}`,
                      selected.unwatched_count ? `${selected.unwatched_count} unwatched` : null,
                    ]
                      .filter(Boolean)
                      .join(" · ")}
                  </p>
                ) : null}
              </div>
              <Segmented segments={FILTERS} value={unwatched ? "unwatched" : "all"} onChange={setFilter} label="Filter" />
              <Button variant="secondary" onClick={markAllWatched} disabled={marking || unwatchedCount === 0}>
                <CheckCheck className="h-4 w-4" aria-hidden />
                {marking ? "Marking…" : "Mark all as watched"}
              </Button>
              {selected ? <ChannelActions channel={selected} onHidden={() => dropSelection(selected.id)} className="lg:hidden" /> : null}
              {selected ? (
                <Link to={`/channel/${selected.id}`} className="inline-flex items-center gap-1 text-sm text-primary hover:underline">
                  Channel page
                  <ChevronRight className="h-4 w-4" aria-hidden />
                </Link>
              ) : null}
            </div>
            <VideoFeed key={`${selected?.id ?? "all"}-${unwatched}`} library={library} channelId={selected?.id ?? null} unwatched={unwatched} />
          </section>
        </div>
      )}
    </div>
  );
}

function ChannelLink({
  to,
  current,
  label,
  count,
  hasActions = false,
  children,
}: {
  to: { search: string };
  current: boolean;
  label: string;
  count: number;
  /** A "…" sits over the row's right end: the count makes way for it. */
  hasActions?: boolean;
  children: ReactNode;
}) {
  return (
    <Link
      to={to}
      replace
      aria-current={current ? "page" : undefined}
      className={cn(
        "flex items-center gap-2.5 rounded-[var(--radius-control)] px-3 py-2 text-sm lg:py-1.5",
        current ? "bg-primary/10 font-medium text-primary" : "text-muted hover:bg-surface-raised hover:text-foreground",
        // Room for the "…" while it shows, and always on a touch screen, where it never hides.
        hasActions && "lg:group-focus-within:pr-9 lg:group-hover:pr-9 lg:[@media(hover:none)]:pr-9",
        hasActions && !current && "lg:group-hover:bg-surface-raised lg:group-hover:text-foreground",
      )}
    >
      {children}
      <span className="min-w-0 max-w-[10rem] truncate lg:max-w-none lg:flex-1">{label}</span>
      {count > 0 ? (
        <span
          className={cn(
            "rounded-full bg-primary px-1.5 text-xs font-semibold tabular-nums text-primary-foreground",
            hasActions &&
              "lg:[@media(hover:hover)]:group-hover:invisible lg:[@media(hover:hover)]:group-focus-within:invisible lg:[@media(hover:hover)]:group-has-[[aria-expanded=true]]:invisible",
          )}
          aria-label={`${count} unwatched`}
        >
          {count}
        </span>
      ) : null}
    </Link>
  );
}

/** The feed: newest first, a page at a time. */
function VideoFeed({ library, channelId, unwatched }: { library: Library; channelId: string | null; unwatched: boolean }) {
  const filters = { library_id: library.id, channel_id: channelId ?? undefined, unwatched };
  const videos = useInfiniteQuery({
    queryKey: keys.videos.feed(filters),
    queryFn: ({ pageParam, signal }) => {
      const search = new URLSearchParams({ library_id: library.id, page: String(pageParam), per: String(PAGE) });
      if (channelId) search.set("channel_id", channelId);
      if (unwatched) search.set("unwatched", "true");
      return api.get<VideoCard[]>(`/videos?${search.toString()}`, { signal });
    },
    initialPageParam: 1,
    getNextPageParam: (last, pages) => (last.length === PAGE ? pages.length + 1 : undefined),
  });

  if (videos.isPending) return <LoadingState />;
  if (videos.isError) return <ErrorState message="Could not load videos." onRetry={() => void videos.refetch()} />;
  const cards = videos.data.pages.flat();
  if (cards.length === 0) return <EmptyState title={unwatched ? "All caught up" : "No videos yet"} />;
  return (
    <>
      <div className={VIDEO_GRID}>
        {cards.map((video) => (
          <VideoTile key={video.id} video={video} showChannel={!channelId} />
        ))}
      </div>
      <LoadMore
        hasMore={videos.hasNextPage}
        loading={videos.isFetchingNextPage}
        failed={videos.isFetchNextPageError}
        onLoad={() => void videos.fetchNextPage()}
      />
    </>
  );
}
