import { Link } from "react-router-dom";
import { Check, Play, X } from "lucide-react";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { ProgressBar } from "@/components/ui/ProgressBar";
import { IconButton } from "@/components/ui/IconButton";
import { ItemActions } from "@/components/viewing/ItemActions";
import { cn } from "@/lib/cn";
import type { EpisodeCard, MissingPart, MovieCard, ShowCard, VideoCard } from "@/types";

const POSTER_SIZES = "(min-width: 1280px) 12rem, (min-width: 768px) 10rem, 40vw";
const WIDE_SIZES = "(min-width: 1280px) 20rem, (min-width: 768px) 18rem, 75vw";

function TitleFallback({ title }: { title: string }) {
  return <span className="line-clamp-3 px-3 text-center text-sm font-medium text-muted">{title}</span>;
}

/** A movie or show in a grid: the poster, with watched and unwatched marks. */
export function PosterCard({ item, className }: { item: MovieCard | ShowCard; className?: string }) {
  const href = item.kind === "movie" ? `/movie/${item.id}` : `/show/${item.id}`;
  const poster = item.images.poster ?? null;
  return (
    <div className={cn("group relative min-w-0", className)}>
    <Link to={href} className="block">
      <div className="relative">
        <ArtworkImage
          image={poster ?? item.images.thumb}
          sizes={POSTER_SIZES}
          alt=""
          className="aspect-[2/3] rounded-[var(--radius-card)] ring-1 ring-border transition group-hover:ring-2 group-hover:ring-primary"
          fallback={<TitleFallback title={item.title} />}
        />
        {item.kind === "movie" && item.watched ? (
          <span className="absolute right-1.5 top-1.5 rounded-full bg-primary p-1 text-primary-foreground" title="Watched">
            <Check className="h-3 w-3" aria-hidden />
          </span>
        ) : null}
        {item.kind === "show" && item.unwatched_count > 0 ? (
          <span className="absolute right-1.5 top-1.5 rounded-full bg-primary px-1.5 py-0.5 text-xs font-semibold tabular-nums text-primary-foreground">
            {item.unwatched_count}
          </span>
        ) : null}
        {item.kind === "movie" && item.progress ? (
          <ProgressBar variant="overlay" value={item.progress} className="absolute inset-x-0 bottom-0 overflow-hidden rounded-b-[var(--radius-card)]" />
        ) : null}
      </div>
      <p className="mt-2 truncate text-sm font-medium text-foreground">{item.title}</p>
      <p className="truncate text-xs text-muted">{(item.kind === "show" ? item.arrival : null) ?? item.credit ?? item.year ?? " "}</p>
    </Link>
      {/* Over the poster's bottom-right corner, beside the link rather than in it. */}
      <div className="pointer-events-none absolute inset-x-0 top-0 aspect-[2/3]">
        <ItemActions item={item} className="pointer-events-auto absolute bottom-1.5 right-1.5" />
      </div>
    </div>
  );
}

/**
 * A film in a series that no library has (a TMDB collection's): its poster
 * faded, so the whole series shows and what's missing is plain. Not a link:
 * there's nothing here to open.
 */
export function MissingPosterCard({ part, className }: { part: MissingPart; className?: string }) {
  const coming = part.release_date !== null && new Date(part.release_date) > new Date();
  const note = coming ? `Coming ${part.year ?? "soon"}` : "Not in your library";
  return (
    <div
      role="group"
      aria-label={`${part.title}${part.year ? ` (${part.year})` : ""}: ${note.toLowerCase()}`}
      title={part.overview ?? undefined}
      className={cn("min-w-0", className)}
    >
      <ArtworkImage
        image={part.images.poster ?? null}
        sizes={POSTER_SIZES}
        alt=""
        className="aspect-[2/3] rounded-[var(--radius-card)] opacity-40 ring-1 ring-border grayscale"
        fallback={<TitleFallback title={part.title} />}
      />
      <p className="mt-2 truncate text-sm font-medium text-muted">{part.title}</p>
      <p className="truncate text-xs text-muted">{[part.year, note].filter(Boolean).join(" · ")}</p>
    </div>
  );
}

/**
 * A 16:9 card that plays when pressed: Continue watching and Next up. An
 * episode shows its still (or a frame), a movie its backdrop.
 */
export function WideCard({
  item,
  className,
  onDismiss,
}: {
  item: MovieCard | ShowCard | EpisodeCard | VideoCard;
  className?: string;
  /** Dismissal from a Home row, named for the label: "Continue watching", "Next up". */
  onDismiss?: { from: string; dismiss: () => void };
}) {
  const image =
    item.kind === "episode"
      ? (item.images.still ?? item.images.thumb ?? item.show?.images.backdrop)
      : item.kind === "video"
        ? item.images.thumb
        : (item.images.backdrop ?? item.images.thumb);
  const heading = item.kind === "episode" ? (item.show?.title ?? "") : item.title;
  const detail =
    item.kind === "episode"
      ? [item.code, item.title].filter(Boolean).join(" · ")
      : item.kind === "video"
        ? null
        : item.kind === "show"
          ? (item.arrival ?? item.year?.toString())
          : item.year?.toString();
  // A show stands in a row for a batch of its episodes (Recently added): it
  // opens the show, on the season they came in when there was one.
  const href =
    item.kind === "show" ? `/show/${item.id}${item.season_number != null ? `?season=${item.season_number}` : ""}` : `/watch/${item.kind}/${item.id}`;
  const progress = item.kind === "show" ? null : item.progress;
  // A video's channel is its own link, to the channel's page — beside the
  // card's link rather than in it.
  const channel = item.kind === "video" ? item.channel : null;
  return (
    <div className={cn("group relative min-w-0", className)}>
    <Link to={href} className="block">
      <div className="relative">
        <ArtworkImage
          image={image}
          sizes={WIDE_SIZES}
          className="aspect-video rounded-[var(--radius-card)] ring-1 ring-border transition group-hover:ring-2 group-hover:ring-primary"
          fallback={<TitleFallback title={heading} />}
        />
        {item.kind === "show" ? (
          item.unwatched_count > 0 ? (
            <span className="absolute right-1.5 top-1.5 rounded-full bg-primary px-1.5 py-0.5 text-xs font-semibold tabular-nums text-primary-foreground">
              {item.unwatched_count}
            </span>
          ) : null
        ) : (
          <span className="absolute inset-0 flex items-center justify-center opacity-0 transition group-hover:opacity-100 group-focus-visible:opacity-100">
            <span className="rounded-full bg-background/80 p-3 text-foreground">
              <Play className="h-5 w-5 fill-current" aria-hidden />
            </span>
          </span>
        )}
        {progress ? (
          <ProgressBar variant="overlay" value={progress} className="absolute inset-x-0 bottom-0 overflow-hidden rounded-b-[var(--radius-card)]" />
        ) : null}
      </div>
      <p className="mt-2 truncate text-sm font-medium text-foreground">{heading}</p>
      {detail ? <p className="truncate text-xs text-muted">{detail}</p> : null}
    </Link>
      {channel ? (
        <Link to={`/channel/${channel.id}`} className="block truncate text-xs text-muted hover:text-foreground">
          {channel.title}
        </Link>
      ) : null}
      <div className="pointer-events-none absolute inset-x-0 top-0 aspect-video">
        <ItemActions item={item} className="pointer-events-auto absolute bottom-1.5 right-1.5" />
      </div>
      {onDismiss ? (
        <IconButton
          label={`Remove ${heading} from ${onDismiss.from}`}
          onClick={onDismiss.dismiss}
          className="absolute right-1.5 top-1.5 rounded-full bg-background/80 text-foreground opacity-0 focus-visible:opacity-100 group-hover:opacity-100"
        >
          <X className="h-3.5 w-3.5" aria-hidden />
        </IconButton>
      ) : null}
    </div>
  );
}
