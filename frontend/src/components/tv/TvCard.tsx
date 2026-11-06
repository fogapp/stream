import { Link } from "react-router-dom";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { ProgressBar } from "@/components/ui/ProgressBar";
import { cn } from "@/lib/cn";
import type { ImageInfo } from "@/types";

/** A card a remote can land on: a poster (tall) or a still (wide). */
export function TvCard({
  to,
  image,
  title,
  detail,
  progress,
  wide = false,
}: {
  to: string;
  image: ImageInfo | null | undefined;
  title: string;
  detail?: string | null;
  progress?: number | null;
  wide?: boolean;
}) {
  return (
    <Link to={to} data-tv className={cn("group block shrink-0 rounded-[var(--radius-card)] transition-transform focus:scale-105", wide ? "w-80" : "w-48")}>
      <div className="relative">
        <ArtworkImage
          image={image}
          sizes={wide ? "20rem" : "12rem"}
          className={cn("rounded-[var(--radius-card)] ring-1 ring-border", wide ? "aspect-video" : "aspect-[2/3]")}
          fallback={<span className="px-3 text-center text-lg text-muted">{title}</span>}
        />
        {progress ? <ProgressBar variant="overlay" value={progress} className="absolute inset-x-0 bottom-0 overflow-hidden rounded-b-[var(--radius-card)]" /> : null}
      </div>
      <p className="mt-3 truncate text-lg font-medium">{title}</p>
      {detail ? <p className="truncate text-base text-muted">{detail}</p> : null}
    </Link>
  );
}
