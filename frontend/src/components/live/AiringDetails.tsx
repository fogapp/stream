import type { ReactNode } from "react";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { cn } from "@/lib/cn";
import { clockTime } from "@/lib/live";
import type { Airing, Station } from "@/types";

/** A program's when and what, for the guide's panel and its sheet. */
export function AiringDetails({
  airing,
  station,
  timeZone,
  showReason,
  compact = false,
  picture,
}: {
  airing: Airing;
  station: Station;
  timeZone: string;
  /** Why the schedule chose it — for admins. */
  showReason: boolean;
  compact?: boolean;
  /** In place of the still: the guide's live preview. */
  picture?: ReactNode;
}) {
  const minutes = Math.round((Date.parse(airing.ends_at) - Date.parse(airing.starts_at)) / 60_000);
  const day = new Intl.DateTimeFormat(undefined, { weekday: "short", timeZone }).format(new Date(airing.starts_at));
  const image = airing.images.still ?? airing.images.backdrop ?? airing.images.poster;
  return (
    <div className="flex min-w-0 gap-4">
      {picture ?? (
        <div className={cn("shrink-0 overflow-hidden rounded-[var(--radius-control)] bg-surface-raised", compact ? "hidden aspect-video w-40 sm:block" : "aspect-video w-full max-w-72")}>
          <ArtworkImage image={image} sizes="288px" className="h-full w-full object-cover" />
        </div>
      )}
      <div className="min-w-0 flex-1 space-y-1">
        <p className="text-xs uppercase tracking-wide text-muted">
          {station.number} · {station.name}
        </p>
        <p className="truncate text-lg font-semibold">{airing.title}</p>
        {airing.subtitle ? <p className="truncate text-sm">{airing.subtitle}</p> : null}
        <p className="text-sm text-muted">
          {[`${day} ${clockTime(airing.starts_at, timeZone, false)} – ${clockTime(airing.ends_at, timeZone)}`, `${minutes} min`, airing.content_rating]
            .filter(Boolean)
            .join(" · ")}
        </p>
        {airing.overview ? <p className={cn("text-sm text-muted", compact ? "line-clamp-2" : "line-clamp-4")}>{airing.overview}</p> : null}
        {showReason ? <p className="text-xs text-muted">Why: {airing.reason}</p> : null}
      </div>
    </div>
  );
}
