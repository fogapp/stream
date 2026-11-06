import { Link } from "react-router-dom";
import { Play } from "lucide-react";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { ROW_WIDE, Row } from "@/components/viewing/Row";
import { formatClock } from "@/lib/format";
import type { ExtraCard } from "@/types";

/** Trailers, featurettes, deleted scenes… (PROPOSAL §4.2), each one press from playing. */
export function Extras({ extras }: { extras: ExtraCard[] }) {
  if (extras.length === 0) return null;
  return (
    <Row title="Extras">
      {extras.map((extra) => (
        <Link key={extra.id} to={`/watch/extra/${extra.id}`} className={`group block min-w-0 ${ROW_WIDE}`}>
          <div className="relative">
            <ArtworkImage
              image={extra.images.thumb}
              sizes="(min-width: 1280px) 20rem, (min-width: 768px) 18rem, 75vw"
              className="aspect-video rounded-[var(--radius-card)] ring-1 ring-border transition group-hover:ring-2 group-hover:ring-primary"
              fallback={<span className="px-3 text-center text-sm font-medium text-muted">{extra.title}</span>}
            />
            <span className="absolute inset-0 flex items-center justify-center opacity-0 transition group-hover:opacity-100 group-focus-visible:opacity-100">
              <span className="rounded-full bg-background/80 p-3 text-foreground">
                <Play className="h-5 w-5 fill-current" aria-hidden />
              </span>
            </span>
            {extra.duration_seconds ? (
              <span className="absolute bottom-1.5 right-1.5 rounded bg-background/80 px-1.5 py-0.5 font-mono text-xs tabular-nums text-foreground">
                {formatClock(extra.duration_seconds)}
              </span>
            ) : null}
          </div>
          <p className="mt-2 truncate text-sm font-medium text-foreground">{extra.title}</p>
          <p className="truncate text-xs text-muted">
            {[extra.kind_label, extra.season_number !== null ? `Season ${extra.season_number}` : null].filter(Boolean).join(" · ")}
          </p>
        </Link>
      ))}
    </Row>
  );
}
