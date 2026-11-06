import { useQuery } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { UserRound } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { PageHeader } from "@/components/layout/PageHeader";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { VideoTile } from "@/components/viewing/VideoTile";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import { VIDEO_GRID } from "@/pages/ChannelDetail";
import type { SubscriptionsFeed } from "@/types";

/**
 * Subscriptions (PROPOSAL §5.4): this profile's channels' videos, newest
 * first, with unwatched dots — the YouTube home people actually use,
 * without the algorithm.
 */
export function Subscriptions() {
  const feed = useQuery({ queryKey: keys.subscriptions.feed(), queryFn: ({ signal }) => api.get<SubscriptionsFeed>("/subscriptions?per=120", { signal }) });
  return (
    <div className="space-y-6 px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
      <PageHeader title="Subscriptions" description="New videos from the channels you subscribe to, newest first." />
      <QueryState query={feed} errorMessage="Could not load your subscriptions.">
        {(data) =>
          data.channels.length === 0 ? (
            <EmptyState title="No subscriptions yet" description="Subscribe to a channel from its page, and its new videos show up here." />
          ) : (
            <>
              <div className="scrollbar-none -mx-4 flex gap-4 overflow-x-auto px-4 pb-1 sm:-mx-6 sm:px-6 lg:-mx-8 lg:px-8">
                {data.channels.map((channel) => (
                  <Link key={channel.id} to={`/channel/${channel.id}`} className="flex w-20 shrink-0 flex-col items-center text-center">
                    <span className="relative">
                      <ArtworkImage
                        image={channel.avatar}
                        sizes="4rem"
                        className="h-16 w-16 rounded-full ring-1 ring-border"
                        fallback={<UserRound className="h-6 w-6 text-muted" aria-hidden />}
                      />
                      {channel.unwatched_count > 0 ? (
                        <span className="absolute bottom-0 right-0 h-3 w-3 rounded-full bg-primary ring-2 ring-background" title="New videos" />
                      ) : null}
                    </span>
                    <span className="mt-1.5 w-full truncate text-xs text-foreground">{channel.title}</span>
                  </Link>
                ))}
              </div>
              {data.videos.length === 0 ? (
                <EmptyState title="Nothing yet" description="Their videos show up here as they arrive." />
              ) : (
                <div className={VIDEO_GRID}>
                  {data.videos.map((video) => (
                    <VideoTile key={video.id} video={video} />
                  ))}
                </div>
              )}
            </>
          )
        }
      </QueryState>
    </div>
  );
}
