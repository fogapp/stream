import { Link } from "react-router-dom";
import { Heart } from "lucide-react";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { ProgressBar } from "@/components/ui/ProgressBar";
import { ItemActions } from "@/components/viewing/ItemActions";
import { cn } from "@/lib/cn";
import { formatCaptured, formatClock } from "@/lib/format";
import type { ClipCard } from "@/types";

/** A home video: its picture and length, when it was taken and where. */
export function ClipTile({ clip, className, showDate = false }: { clip: ClipCard; className?: string; showDate?: boolean }) {
  const when = showDate
    ? formatCaptured(clip, { dateStyle: "medium" })
    : formatCaptured(clip, { weekday: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  return (
    <div className={cn("group relative min-w-0", className)}>
    <Link to={`/clip/${clip.id}`} className="block">
      <div className="relative">
        <ArtworkImage
          image={clip.images.thumb}
          sizes="(min-width: 1280px) 16rem, (min-width: 640px) 30vw, 45vw"
          className="aspect-video rounded-[var(--radius-card)] ring-1 ring-border transition group-hover:ring-2 group-hover:ring-primary"
          fallback={<span className="px-2 text-center text-xs text-muted">{clip.title}</span>}
        />
        {clip.duration_seconds ? (
          <span className="absolute bottom-1.5 right-1.5 rounded bg-background/85 px-1.5 py-0.5 font-mono text-xs tabular-nums text-foreground transition [@media(hover:hover)]:group-focus-within:opacity-0 [@media(hover:hover)]:group-hover:opacity-0 [@media(hover:none)]:right-11">
            {formatClock(clip.duration_seconds)}
          </span>
        ) : null}
        {clip.favorite ? <Heart className="absolute left-1.5 top-1.5 h-4 w-4 fill-current text-primary" aria-label="Favourite" /> : null}
        {clip.progress ? <ProgressBar variant="overlay" value={clip.progress} className="absolute inset-x-0 bottom-0 overflow-hidden rounded-b-[var(--radius-card)]" /> : null}
      </div>
      <p className="mt-1.5 truncate text-xs text-foreground">{when}</p>
      {clip.city || clip.country ? <p className="truncate text-xs text-muted">{[clip.city, clip.country].filter(Boolean).join(", ")}</p> : null}
    </Link>
      <div className="pointer-events-none absolute inset-x-0 top-0 aspect-video">
        <ItemActions item={clip} className="pointer-events-auto absolute bottom-1.5 right-1.5" />
      </div>
    </div>
  );
}
