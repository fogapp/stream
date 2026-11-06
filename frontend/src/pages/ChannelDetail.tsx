import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useParams, useSearchParams } from "react-router-dom";
import { Bell, BellRing, ExternalLink, UserRound } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { Description } from "@/components/viewing/Description";
import { VideoTile } from "@/components/viewing/VideoTile";
import { ForProfiles } from "@/components/viewing/ForProfiles";
import { HideFromProfile } from "@/components/viewing/HideFromProfile";
import { ChannelTracking } from "@/components/youtube/ChannelTracking";
import { LinkChannel } from "@/components/youtube/LinkChannel";
import { useAuth } from "@/hooks/useAuth";
import { Button } from "@/components/ui/Button";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import { Segmented } from "@/components/ui/Segmented";
import type { ChannelDetail as Channel } from "@/types";

const SORTS = [
  { key: "newest", label: "Newest" },
  { key: "oldest", label: "Oldest" },
  { key: "title", label: "A–Z" },
] as const;
const FILTERS = [
  { key: "all", label: "All" },
  { key: "unwatched", label: "Unwatched" },
] as const;
type Sort = (typeof SORTS)[number]["key"];

export const VIDEO_GRID = "grid grid-cols-1 gap-x-4 gap-y-6 sm:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-4";

/** A channel (PROPOSAL §5.4): banner, avatar, what it's about, and its videos. */
export function ChannelDetail() {
  const { id = "" } = useParams();
  const [params, setParams] = useSearchParams();
  const sort: Sort = SORTS.some((option) => option.key === params.get("sort")) ? (params.get("sort") as Sort) : "newest";
  const unwatched = params.get("filter") === "unwatched";
  const { user } = useAuth();
  const admin = user?.role === "admin";
  const channel = useQuery({
    queryKey: keys.channels.detail(id, { sort, unwatched }),
    queryFn: ({ signal }) => api.get<Channel>(`/channels/${id}?sort=${sort}${unwatched ? "&unwatched=true" : ""}&per=200`, { signal }),
    placeholderData: (previous) => previous,
  });
  const update = (key: string, value: string, fallback: string) => {
    const next = new URLSearchParams(params);
    if (value === fallback) next.delete(key);
    else next.set(key, value);
    setParams(next, { replace: true });
  };

  return (
    <QueryState query={channel} errorMessage="Could not load this channel.">
      {(data) => (
        <div className="pb-10">
          <div className="aspect-[6/1] max-h-56 w-full overflow-hidden bg-surface">
            {data.banner ? <ArtworkImage image={data.banner} sizes="100vw" className="h-full w-full" eager /> : null}
          </div>
          <div className="space-y-6 px-4 sm:px-6 lg:px-8">
            <header className="flex flex-wrap items-center gap-4 pt-5">
              <ArtworkImage
                image={data.avatar}
                sizes="6rem"
                className="h-20 w-20 shrink-0 rounded-full ring-1 ring-border sm:h-24 sm:w-24"
                fallback={<UserRound className="h-8 w-8 text-muted" aria-hidden />}
                eager
              />
              <div className="min-w-0 flex-1">
                <h1 className="truncate text-2xl font-bold tracking-tight text-foreground sm:text-3xl">{data.title}</h1>
                <p className="text-sm text-muted">
                  {[data.handle, `${data.video_count} ${data.video_count === 1 ? "video" : "videos"}`, data.unwatched_count ? `${data.unwatched_count} unwatched` : null]
                    .filter(Boolean)
                    .join(" · ")}
                </p>
              </div>
              <SubscribeButton channelId={data.id} subscribed={data.subscribed} />
              <ForProfiles item={{ kind: "channel", id: data.id }} align="right" />
              <HideFromProfile item={{ kind: "channel", id: data.id, title: data.title }} size="md" />
              {data.url ? (
                <a href={data.url} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1.5 text-sm text-muted hover:text-foreground">
                  <ExternalLink className="h-4 w-4" aria-hidden />
                  On YouTube
                </a>
              ) : null}
            </header>
            {data.description ? <Description text={data.description} className="max-w-3xl" /> : null}
            {admin ? data.youtube_id ? <ChannelTracking channelId={data.id} /> : <LinkChannel channelId={data.id} /> : null}
            <div className="flex flex-wrap items-center gap-2">
              <Segmented segments={SORTS} value={sort} onChange={(key) => update("sort", key, "newest")} label="Sort" />
              <Segmented segments={FILTERS} value={unwatched ? "unwatched" : "all"} onChange={(key) => update("filter", key, "all")} label="Filter" />
            </div>
            {data.videos.length === 0 ? (
              <EmptyState title={unwatched ? "All caught up" : "No videos yet"} />
            ) : (
              <div className={VIDEO_GRID}>
                {data.videos.map((video) => (
                  <VideoTile key={video.id} video={video} showChannel={false} />
                ))}
              </div>
            )}
          </div>
        </div>
      )}
    </QueryState>
  );
}

function SubscribeButton({ channelId, subscribed }: { channelId: string; subscribed: boolean }) {
  const queryClient = useQueryClient();
  const toggle = useMutation({
    mutationFn: () => (subscribed ? api.delete(`/channels/${channelId}/subscription`) : api.post(`/channels/${channelId}/subscription`)),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: keys.channels.all });
      void queryClient.invalidateQueries({ queryKey: keys.subscriptions.all });
      void queryClient.invalidateQueries({ queryKey: keys.home.all });
    },
  });
  return (
    <Button variant={subscribed ? "secondary" : "primary"} aria-pressed={subscribed} onClick={() => toggle.mutate()} disabled={toggle.isPending}>
      {subscribed ? <BellRing className="h-4 w-4" aria-hidden /> : <Bell className="h-4 w-4" aria-hidden />}
      {subscribed ? "Subscribed" : "Subscribe"}
    </Button>
  );
}
