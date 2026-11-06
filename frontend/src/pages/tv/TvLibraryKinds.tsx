import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { useParams } from "react-router-dom";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { TvCard } from "@/components/tv/TvCard";
import { TvShell } from "@/components/tv/TvShell";
import { EmptyState, LoadingState } from "@/components/ui/PageState";
import type { ChannelCard, ChannelDetail, ClipCard, Library } from "@/types";
import { liveStreamsQuery } from "@/lib/queries";

/** A channels library on the TV: every channel, newest uploads first. */
export function TvChannels({ library }: { library: Library }) {
  const channels = useQuery({
    queryKey: keys.channels.list({ library_id: library.id }),
    queryFn: ({ signal }) => api.get<ChannelCard[]>(`/channels?library_id=${library.id}`, { signal }),
  });
  return (
    <TvShell ready={Boolean(channels.data)}>
      <div className="space-y-8 px-12 pt-8">
        <h1 className="text-3xl font-bold">{library.name}</h1>
        {channels.isError ? (
          <p className="text-xl text-negative">The channels didn't load.</p>
        ) : !channels.data ? (
          <LoadingState />
        ) : channels.data.length === 0 ? (
          <EmptyState title="No channels yet" description="Channels appear here once they're added and their videos fetched." />
        ) : (
          <div className="flex flex-wrap gap-6">
            {channels.data.map((channel) => (
              <TvCard
                key={channel.id}
                wide
                to={`/tv/channel/${channel.id}`}
                image={channel.banner ?? channel.avatar}
                title={channel.title}
                detail={channel.unwatched_count ? `${channel.unwatched_count} unwatched` : `${channel.video_count} videos`}
              />
            ))}
          </div>
        )}
      </div>
    </TvShell>
  );
}

/** One channel on the TV: its videos, newest first. */
export function TvChannel() {
  const { id = "" } = useParams();
  const channel = useQuery({ queryKey: keys.channels.detail(id, { sort: "newest" }), queryFn: ({ signal }) => api.get<ChannelDetail>(`/channels/${id}?sort=newest&per=200`, { signal }) });
  return (
    <TvShell ready={Boolean(channel.data)}>
      <div className="space-y-8 px-12 pt-8">
        {channel.isError ? <p className="text-xl text-negative">This channel didn't load.</p> : null}
        {channel.data ? (
          <>
            <h1 className="text-3xl font-bold">{channel.data.title}</h1>
            <div className="flex flex-wrap gap-6">
              {channel.data.videos.map((video) => (
                <TvCard key={video.id} wide to={`/watch/video/${video.id}`} image={video.images.thumb} title={video.title} progress={video.progress} />
              ))}
            </div>
          </>
        ) : channel.isError ? null : (
          <LoadingState />
        )}
      </div>
    </TvShell>
  );
}

/** A home-videos library on the TV: the clips, newest first, a page at a time. */
export function TvHomeVideos({ library }: { library: Library }) {
  const clips = useInfiniteQuery({
    queryKey: keys.clips.list({ library_id: library.id }),
    queryFn: ({ pageParam, signal }) =>
      api.get<{ clips: ClipCard[]; more: boolean }>(`/clips?library_id=${library.id}${pageParam ? `&before=${encodeURIComponent(pageParam)}` : ""}`, { signal }),
    initialPageParam: null as string | null,
    getNextPageParam: (page) => (page.more ? (page.clips.at(-1)?.captured_at ?? null) : null),
  });
  const all = clips.data?.pages.flatMap((page) => page.clips) ?? [];
  return (
    <TvShell ready={Boolean(clips.data)}>
      <div className="space-y-8 px-12 pt-8">
        <h1 className="text-3xl font-bold">{library.name}</h1>
        {clips.isError ? (
          <p className="text-xl text-negative">The videos didn't load.</p>
        ) : !clips.data ? (
          <LoadingState />
        ) : all.length === 0 ? (
          <EmptyState title="No home videos yet" />
        ) : (
          <>
            <div className="flex flex-wrap gap-6">
              {all.map((clip) => (
                <TvCard
                  key={clip.id}
                  wide
                  to={`/watch/clip/${clip.id}`}
                  image={clip.images.thumb}
                  title={clip.title}
                  detail={[new Date(clip.captured_at).toLocaleDateString(), clip.city].filter(Boolean).join(" · ")}
                  progress={clip.progress}
                />
              ))}
            </div>
            {clips.hasNextPage ? (
              <button type="button" data-tv onClick={() => void clips.fetchNextPage()} className="rounded-[var(--radius-card)] bg-surface-raised px-6 py-3 text-xl">
                {clips.isFetchingNextPage ? "Loading…" : "More"}
              </button>
            ) : null}
          </>
        )}
      </div>
    </TvShell>
  );
}

/** A live library on the TV (PROPOSAL §7.8): each camera and web stream, its latest picture. */
export function TvLiveStreams({ library }: { library: Library }) {
  const streams = useQuery(liveStreamsQuery(library.id));
  return (
    <TvShell ready={Boolean(streams.data)}>
      <div className="space-y-8 px-12 pt-8">
        <h1 className="text-3xl font-bold">{library.name}</h1>
        {streams.isError ? (
          <p className="text-xl text-negative">The streams didn't load.</p>
        ) : !streams.data ? (
          <LoadingState />
        ) : streams.data.length === 0 ? (
          <EmptyState title="No streams yet" />
        ) : (
          <div className="flex flex-wrap gap-6">
            {streams.data.map((stream) => (
              <TvCard
                key={stream.id}
                wide
                to={`/stream/${stream.id}`}
                image={stream.still_url ? { src: stream.still_url, srcset: "", width: 640, height: 360, placeholder: null, color: null } : null}
                title={stream.name}
                detail={stream.status === "offline" ? "Offline" : "Live"}
              />
            ))}
          </div>
        )}
      </div>
    </TvShell>
  );
}
