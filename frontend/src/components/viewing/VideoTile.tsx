import { Link } from "react-router-dom";
import { UserRound } from "lucide-react";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { ProgressBar } from "@/components/ui/ProgressBar";
import { PlayNextButton, videoNext } from "@/components/viewing/PlayNextButton";
import { WatchLaterButton } from "@/components/viewing/WatchLaterButton";
import { MarkWatchedButton } from "@/components/viewing/MarkWatchedButton";
import { ItemActions } from "@/components/viewing/ItemActions";
import { cn } from "@/lib/cn";
import { formatClock } from "@/lib/format";
import { relativeTime } from "@/lib/time";
import type { VideoCard } from "@/types";

/**
 * A channel video, YouTube-style (PROPOSAL §5.4): the thumbnail with its
 * length and progress, an unwatched dot, the title, and whose it is.
 */
export function VideoTile({ video, className, showChannel = true }: { video: VideoCard; className?: string; showChannel?: boolean }) {
  return (
    <div className={cn("group min-w-0", className)}>
      <div className="relative">
        <Link to={`/video/${video.id}`} className="block">
          <div className="relative">
            <ArtworkImage
              image={video.images.thumb}
              sizes="(min-width: 1280px) 20rem, (min-width: 640px) 45vw, 90vw"
              className="aspect-video rounded-[var(--radius-card)] ring-1 ring-border transition group-hover:ring-2 group-hover:ring-primary"
              fallback={<span className="line-clamp-2 px-3 text-center text-sm text-muted">{video.title}</span>}
            />
            {video.duration_seconds ? (
              <span className="absolute bottom-1.5 right-1.5 rounded bg-background/85 px-1.5 py-0.5 font-mono text-xs tabular-nums text-foreground transition [@media(hover:hover)]:group-focus-within:opacity-0 [@media(hover:hover)]:group-hover:opacity-0 [@media(hover:none)]:right-11">
                {formatClock(video.duration_seconds)}
              </span>
            ) : null}
            {video.progress ? (
              <ProgressBar variant="overlay" value={video.progress} className="absolute inset-x-0 bottom-0 overflow-hidden rounded-b-[var(--radius-card)]" />
            ) : null}
          </div>
        </Link>
        <div className="absolute right-1.5 top-1.5 flex gap-1 opacity-0 transition focus-within:opacity-100 group-hover:opacity-100">
          <MarkWatchedButton item={video} className="rounded-full bg-background/85 text-foreground" />
          <WatchLaterButton item={{ kind: "video", id: video.id, title: video.title }} compact className="rounded-full bg-background/85 text-foreground" />
          <PlayNextButton item={videoNext(video)} compact className="rounded-full bg-background/85 text-foreground" />
        </div>
        <ItemActions item={video} className="absolute bottom-1.5 right-1.5" />
      </div>
      <div className="mt-2 flex gap-2.5">
        {showChannel && video.channel ? (
          <Link to={`/channel/${video.channel.id}`} aria-label={video.channel.title} className="shrink-0">
            <ArtworkImage
              image={video.channel.avatar}
              sizes="2.25rem"
              className="h-9 w-9 rounded-full ring-1 ring-border"
              fallback={<UserRound className="h-4 w-4 text-muted" aria-hidden />}
            />
          </Link>
        ) : null}
        <div className="min-w-0 flex-1">
          <Link to={`/video/${video.id}`} className="line-clamp-2 text-sm font-medium leading-snug text-foreground">
            {!video.watched ? (
              <span className="mr-1.5 inline-block h-2 w-2 rounded-full bg-primary align-middle" title="Unwatched" aria-label="Unwatched" />
            ) : null}
            {video.title}
          </Link>
          <p className="truncate text-xs text-muted">
            {showChannel && video.channel ? (
              <Link to={`/channel/${video.channel.id}`} className="hover:text-foreground">
                {video.channel.title}
              </Link>
            ) : null}
            {showChannel && video.channel && video.upload_date ? " · " : null}
            {video.upload_date ? relativeTime(video.upload_date) : null}
          </p>
        </div>
      </div>
    </div>
  );
}
