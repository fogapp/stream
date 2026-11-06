import { useQuery } from "@tanstack/react-query";
import { Link, useParams } from "react-router-dom";
import { MapPin, UserRound } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { formatCaptured, formatClock } from "@/lib/format";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { ClipTile } from "@/components/viewing/ClipTile";
import { PlayButtons } from "@/components/viewing/PlayButton";
import { DownloadButton } from "@/components/viewing/DownloadButton";
import { ProgressBar } from "@/components/ui/ProgressBar";
import { Badge } from "@/components/ui/Badge";
import { QueryState } from "@/components/ui/PageState";
import type { ClipDetail as Clip } from "@/types";

/** A home video: when and where, who's in it, and the rest of that day. */
export function ClipDetail() {
  const { id = "" } = useParams();
  const clip = useQuery({ queryKey: keys.clips.detail(id), queryFn: ({ signal }) => api.get<Clip>(`/clips/${id}`, { signal }) });
  return (
    <QueryState query={clip} errorMessage="Could not load this clip.">
      {(data) => <ClipPage clip={data} />}
    </QueryState>
  );
}

function ClipPage({ clip }: { clip: Clip }) {
  return (
    <div className="space-y-6 px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
      <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]">
        <Link to={`/watch/clip/${clip.id}`} aria-label="Play this clip" className="relative block">
          <ArtworkImage image={clip.images.thumb} sizes="(min-width: 1024px) 60vw, 100vw" className="aspect-video rounded-[var(--radius-card)] ring-1 ring-border" eager />
          {clip.progress ? <ProgressBar variant="overlay" value={clip.progress} className="absolute inset-x-0 bottom-0 overflow-hidden rounded-b-[var(--radius-card)]" /> : null}
        </Link>
        <div className="space-y-4">
          <div>
            <h1 className="text-xl font-bold text-foreground">{formatCaptured(clip, { dateStyle: "full" })}</h1>
            <p className="text-sm text-muted">
              {[formatCaptured(clip, { hour: "numeric", minute: "2-digit" }), clip.duration_seconds ? formatClock(clip.duration_seconds) : null]
                .filter(Boolean)
                .join(" · ")}
            </p>
          </div>
          {clip.city || clip.country ? (
            <p className="flex items-center gap-1.5 text-sm text-foreground">
              <MapPin className="h-4 w-4 text-muted" aria-hidden />
              {[clip.city, clip.country].filter(Boolean).join(", ")}
            </p>
          ) : null}
          <PlayButtons kind="clip" id={clip.id} resumeAt={clip.resume_at} />
          <DownloadButton item={{ type: "clip", id: clip.id }} />
          {clip.description ? <p className="whitespace-pre-line text-sm text-foreground/90">{clip.description}</p> : null}
          {clip.people.length > 0 ? (
            <div className="flex flex-wrap gap-1.5">
              {clip.people.map((person) => (
                <Link key={person.id} to={`/library/${clip.library.id}?person=${person.id}`}>
                  <Badge>
                    <UserRound className="h-3 w-3" aria-hidden />
                    {person.name}
                  </Badge>
                </Link>
              ))}
            </div>
          ) : null}
          {clip.albums.length > 0 ? (
            <p className="text-sm text-muted">
              In{" "}
              {clip.albums.map((album, index) => (
                <span key={album.id}>
                  <Link to={`/library/${clip.library.id}?album=${album.id}`} className="text-foreground hover:underline">
                    {album.title}
                  </Link>
                  {index < clip.albums.length - 1 ? ", " : ""}
                </span>
              ))}
            </p>
          ) : null}
          <p className="text-xs text-muted">{clip.title}</p>
        </div>
      </div>
      {clip.same_day.length > 0 ? (
        <section className="space-y-3">
          <h2 className="text-base font-semibold text-foreground">The same day</h2>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 md:grid-cols-4 xl:grid-cols-6">
            {clip.same_day.map((other) => (
              <ClipTile key={other.id} clip={other} />
            ))}
          </div>
        </section>
      ) : null}
    </div>
  );
}
