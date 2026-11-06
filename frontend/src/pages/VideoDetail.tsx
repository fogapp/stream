import { useCallback, useEffect, type ReactNode } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useParams, useSearchParams } from "react-router-dom";
import { Eye, EyeOff, ExternalLink, Pin, Play, RotateCcw, UserRound } from "lucide-react";
import { api, apiErrorMessage } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { refreshWatched } from "@/lib/watched";
import { formatClock, formatDay } from "@/lib/format";
import { AddToPlaylist } from "@/components/viewing/AddToPlaylist";
import { PlayNextButton, videoNext } from "@/components/viewing/PlayNextButton";
import { WatchLaterButton } from "@/components/viewing/WatchLaterButton";
import { DownloadButton } from "@/components/viewing/DownloadButton";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { Description } from "@/components/viewing/Description";
import { IdentifyVideo } from "@/components/viewing/IdentifyVideo";
import { PlayOnScreen } from "@/components/remote/PlayOnScreen";
import { ProgressBar } from "@/components/ui/ProgressBar";
import { TranscriptPanel } from "@/components/viewing/TranscriptPanel";
import { VideoTile } from "@/components/viewing/VideoTile";
import { Button } from "@/components/ui/Button";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { toast } from "@/components/ui/Toast";
import { LoadingState, QueryState } from "@/components/ui/PageState";
import { usePlayback } from "@/hooks/usePlayback";
import { useProfile } from "@/hooks/useProfile";
import { cn } from "@/lib/cn";
import type { VideoDetail as Video } from "@/types";

/**
 * A video's watch page (PROPOSAL §5.4), YouTube's layout: the video playing
 * in the page (or across it, or over the window), the title and channel, the description with its links and
 * timestamps live, the chapters, and more from the channel beside it.
 */
export function VideoDetail() {
  const { id = "" } = useParams();
  const video = useQuery({ queryKey: keys.videos.detail(id), queryFn: ({ signal }) => api.get<Video>(`/videos/${id}`, { signal }) });
  return (
    <QueryState query={video} errorMessage="Could not load this video.">
      {(data) => <VideoPage video={data} />}
    </QueryState>
  );
}

function VideoPage({ video }: { video: Video }) {
  const queryClient = useQueryClient();
  const toggle = useMutation({
    mutationFn: () => api.post("/watch_states", { playable_type: "video", playable_id: video.id, watched: !video.watched }),
    onSuccess: () => refreshWatched(queryClient, { kind: "video", id: video.id, watched: !video.watched }),
  });

  const retention = video.retention;
  const keep = useMutation({
    mutationFn: (kept: boolean) => api.patch(`/channels/${video.channel?.id ?? ""}/tracking/downloads/${retention?.download_id ?? ""}`, { kept }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: keys.videos.all });
      void queryClient.invalidateQueries({ queryKey: keys.youtube.all });
    },
  });
  // It came down wrong: fetch it from YouTube again, over the file there.
  const again = useMutation({
    mutationFn: () => api.post(`/channels/${video.channel?.id ?? ""}/tracking/downloads/${retention?.download_id ?? ""}/retry`),
    onSuccess: () => {
      toast.info(`Downloading ${video.title} again`);
      void queryClient.invalidateQueries({ queryKey: keys.youtube.all });
    },
    onError: (error) => toast.error(apiErrorMessage(error, "Couldn't download it again.")),
  });

  const { current, pending, play, seek, size } = usePlayback();
  const [params, setParams] = useSearchParams();
  const stamp = params.get("t");
  const at = stamp === null ? Number.NaN : Number(stamp);

  // A timestamp (?t=): jump there in place, or start there.
  useEffect(() => {
    if (!(at >= 0) || !video.playable) return;
    if (!seek(video.id, at)) play("video", video.id, { startAt: at });
    const next = new URLSearchParams(params);
    next.delete("t");
    setParams(next, { replace: true });
    // Only for a new timestamp.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [at, video.id]);

  // Opening the page plays it, as YouTube does, unless something else is
  // already playing: that carries on in the corner until Play is pressed —
  // or, for a profile that autoplays, gives way to this.
  const { profile } = useProfile();
  const autoplay = profile?.autoplay_videos ?? false;
  useEffect(() => {
    if (video.playable && !(at >= 0) && (autoplay || (!current && !pending))) play("video", video.id);
    // Only on arriving.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [video.id]);

  const wide = size === "wide";
  const slot = <PlayerSlot video={video} playing={current?.id === video.id} pending={pending} wide={wide} onPlay={() => play("video", video.id)} />;

  return (
    <div className="space-y-8 px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
    {wide ? slot : null}
    <div className="grid gap-8 lg:grid-cols-[minmax(0,1fr)_22rem]">
      <div className="min-w-0 space-y-4">
        {wide ? null : slot}
        <h1 className="text-xl font-bold leading-snug text-foreground sm:text-2xl">{video.title}</h1>
        <div className="flex flex-wrap items-center gap-3">
          {video.channel ? (
            <Link to={`/channel/${video.channel.id}`} className="flex items-center gap-2.5">
              <ArtworkImage
                image={video.channel.avatar}
                sizes="2.5rem"
                className="h-10 w-10 rounded-full ring-1 ring-border"
                fallback={<UserRound className="h-4 w-4 text-muted" aria-hidden />}
              />
              <span className="font-medium text-foreground">{video.channel.title}</span>
            </Link>
          ) : null}
          <span className="flex-1" />
          {video.playable ? <PlayOnScreen kind="video" id={video.id} /> : null}
          <Button variant="ghost" onClick={() => toggle.mutate()} disabled={toggle.isPending}>
            {video.watched ? <EyeOff className="h-4 w-4" aria-hidden /> : <Eye className="h-4 w-4" aria-hidden />}
            {video.watched ? "Mark unwatched" : "Mark watched"}
          </Button>
          {retention && video.channel && (retention.keep_last !== null || retention.kept) ? (
            <Button
              variant="ghost"
              aria-pressed={retention.kept}
              title={
                retention.kept
                  ? "Kept whatever the channel's keep-last rule says"
                  : `Keep it when it's no longer one of the newest ${retention.keep_last ?? ""} downloads`
              }
              onClick={() => keep.mutate(!retention.kept)}
              disabled={keep.isPending}
            >
              <Pin className={cn("h-4 w-4", retention.kept && "fill-current text-primary")} aria-hidden />
              {retention.kept ? "Kept" : "Keep"}
            </Button>
          ) : null}
          {retention && video.channel ? (
            <ConfirmButton
              variant="ghost"
              size="md"
              question="Replace the file with a fresh download?"
              onConfirm={() => again.mutate()}
              disabled={again.isPending || again.isSuccess}
            >
              <RotateCcw className="h-4 w-4" aria-hidden />
              {again.isSuccess ? "Downloading…" : "Download again"}
            </ConfirmButton>
          ) : null}
          <WatchLaterButton item={{ kind: "video", id: video.id, title: video.title }} />
          <DownloadButton item={{ type: "video", id: video.id }} />
          <PlayNextButton item={videoNext(video)} />
          <AddToPlaylist item={{ kind: "video", id: video.id }} align="right" />
        </div>
        <p className="text-sm text-muted">
          {[formatDay(video.upload_date), video.duration_seconds ? formatClock(video.duration_seconds) : null]
            .filter(Boolean)
            .join(" · ")}
          {video.url ? (
            <a href={video.url} target="_blank" rel="noopener noreferrer" className="ml-3 inline-flex items-center gap-1 hover:text-foreground">
              <ExternalLink className="h-3.5 w-3.5" aria-hidden />
              On YouTube
            </a>
          ) : null}
        </p>
        {video.description ? <Description text={video.description} videoId={video.id} defaultOpen /> : null}
        <IdentifyVideo video={video} />
        <TranscriptPanel kind="video" id={video.id} />
        {video.chapters.length > 0 ? (
          <section className="space-y-2">
            <h2 className="text-base font-semibold text-foreground">Chapters</h2>
            <ol className="divide-y divide-border rounded-[var(--radius-card)] border border-border">
              {video.chapters.map((chapter) => (
                <li key={chapter.start}>
                  <Link
                    to={`/video/${video.id}?t=${Math.floor(chapter.start)}`}
                    className="flex items-center gap-3 px-3 py-2 text-sm hover:bg-surface"
                  >
                    <span className="w-14 shrink-0 font-mono tabular-nums text-primary">{formatClock(chapter.start)}</span>
                    <span className="min-w-0 truncate text-foreground">{chapter.title}</span>
                  </Link>
                </li>
              ))}
            </ol>
          </section>
        ) : null}
      </div>
      {video.more_from_channel.length > 0 || video.related.length > 0 ? (
        <aside className="space-y-8">
          {video.more_from_channel.length > 0 ? (
            <SideSection label={`More from ${video.channel?.title ?? "this channel"}`}>
              {video.more_from_channel.map((other) => (
                <VideoTile key={other.id} video={other} showChannel={false} />
              ))}
            </SideSection>
          ) : null}
          {video.related.length > 0 ? (
            <SideSection label="Related videos">
              {video.related.map((other) => (
                <VideoTile key={other.id} video={other} />
              ))}
            </SideSection>
          ) : null}
        </aside>
      ) : null}
    </div>
    </div>
  );
}

/**
 * One list beside the video. In the side column it's a window onto the list
 * that scrolls on its own, two and a half tiles tall: two tiles (a 22rem
 * thumbnail, a two-line title and its date), their gaps, and half the third
 * thumbnail, so there's plainly more below. Under the video (below `lg`) it
 * is the page that scrolls.
 */
function SideSection({ label, children }: { label: string; children: ReactNode }) {
  return (
    <section aria-label={label} className="space-y-4">
      <h2 className="text-base font-semibold text-foreground">{label}</h2>
      {/* The padding keeps a tile's hover and focus rings inside the scrolling box. */}
      <div className="grid gap-5 sm:grid-cols-2 lg:-mx-1 lg:max-h-[40.5rem] lg:grid-cols-1 lg:overflow-y-auto lg:p-1">{children}</div>
    </section>
  );
}

/**
 * Where the player goes on the page. The player itself lives above the
 * router and is laid over this box while the video plays, so changing its
 * size, or leaving for another page, never starts it over.
 */
function PlayerSlot({
  video,
  playing,
  pending,
  wide,
  onPlay,
}: {
  video: Video;
  playing: boolean;
  pending: boolean;
  wide: boolean;
  onPlay: () => void;
}) {
  const { setSlot } = usePlayback();
  const ref = useCallback((element: HTMLDivElement | null) => setSlot(video.id, element), [setSlot, video.id]);
  return (
    <div
      ref={ref}
      className={cn(
        "relative w-full overflow-hidden rounded-[var(--radius-card)] bg-background ring-1 ring-border",
        // Across the page, as tall as the window leaves room for.
        wide ? "aspect-video max-h-[calc(100dvh-10rem)]" : "aspect-video",
      )}
    >
      {playing ? null : (
        <>
          <ArtworkImage image={video.images.thumb} sizes={wide ? "100vw" : "(min-width: 1024px) 60vw, 100vw"} className="h-full w-full" eager />
          {video.progress ? <ProgressBar variant="overlay" value={video.progress} className="absolute inset-x-0 bottom-0" /> : null}
          {video.playable ? (
            <button
              type="button"
              aria-label={`Play ${video.title}`}
              onClick={onPlay}
              disabled={pending}
              className="group absolute inset-0 flex items-center justify-center"
            >
              {pending ? (
                <LoadingState label="Starting…" />
              ) : (
                <span className="flex h-16 w-16 items-center justify-center rounded-full bg-background/80 text-foreground ring-1 ring-border transition group-hover:bg-primary group-hover:text-primary-foreground">
                  <Play className="h-7 w-7 fill-current" aria-hidden />
                </span>
              )}
            </button>
          ) : null}
        </>
      )}
    </div>
  );
}
