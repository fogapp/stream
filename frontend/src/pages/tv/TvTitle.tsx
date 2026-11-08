import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useNavigate, useParams } from "react-router-dom";
import { Play, RotateCcw } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { seasonQuery } from "@/lib/queries";
import { formatClock } from "@/lib/format";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { TvShell } from "@/components/tv/TvShell";
import { QueryState } from "@/components/ui/PageState";
import type { MovieDetail, ShowDetail } from "@/types";

const BUTTON = "inline-flex items-center gap-3 rounded-[var(--radius-card)] bg-surface-raised px-8 py-4 text-xl font-semibold focus:bg-primary focus:text-primary-foreground";

/** A movie or show on the TV: its picture, what it's about, and Play. */
export function TvTitle({ kind }: { kind: "movie" | "show" }) {
  const { id = "" } = useParams();
  const title = useQuery({
    queryKey: kind === "movie" ? keys.movies.detail(id) : keys.shows.detail(id),
    queryFn: ({ signal }) => api.get<MovieDetail | ShowDetail>(`/${kind === "movie" ? "movies" : "shows"}/${id}`, { signal }),
  });
  return (
    <TvShell ready={Boolean(title.data)}>
      <QueryState query={title} errorMessage={`Could not load this ${kind}.`}>
        {(data) => (kind === "movie" ? <MovieView movie={data as MovieDetail} /> : <ShowView show={data as ShowDetail} />)}
      </QueryState>
    </TvShell>
  );
}

function Backdrop({ images, title, children }: { images: MovieDetail["images"]; title: string; children: React.ReactNode }) {
  return (
    <section className="relative isolate min-h-[60vh] px-12 pt-16">
      <div className="absolute inset-0 -z-10">
        <ArtworkImage image={images.backdrop ?? images.thumb} sizes="100vw" className="h-full w-full" eager />
        <div className="absolute inset-0 bg-gradient-to-r from-background via-background/80 to-transparent" />
        <div className="absolute inset-0 bg-gradient-to-t from-background via-transparent to-transparent" />
      </div>
      <div className="max-w-3xl space-y-6">
        <h1 className="text-5xl font-bold tracking-tight">{title}</h1>
        {children}
      </div>
    </section>
  );
}

function MovieView({ movie }: { movie: MovieDetail }) {
  const navigate = useNavigate();
  const resuming = movie.resume_at !== null && movie.resume_at > 0;
  return (
    <Backdrop images={movie.images} title={movie.title}>
      <p className="text-xl text-muted">{[movie.year, movie.content_rating].filter(Boolean).join(" · ")}</p>
      {movie.overview ? <p className="line-clamp-4 text-xl leading-relaxed text-foreground/90">{movie.overview}</p> : null}
      <div className="flex gap-4">
        <button type="button" data-tv data-tv-autofocus data-watch={`/watch/movie/${movie.id}`} className={BUTTON} onClick={() => navigate(`/watch/movie/${movie.id}`)}>
          <Play className="h-6 w-6 fill-current" aria-hidden />
          {resuming ? `Resume from ${formatClock(movie.resume_at ?? 0)}` : "Play"}
        </button>
        {resuming ? (
          <button type="button" data-tv data-watch={`/watch/movie/${movie.id}?from=start`} className={BUTTON} onClick={() => navigate(`/watch/movie/${movie.id}?from=start`)}>
            <RotateCcw className="h-6 w-6" aria-hidden />
            Start over
          </button>
        ) : null}
      </div>
    </Backdrop>
  );
}

function ShowView({ show }: { show: ShowDetail }) {
  const navigate = useNavigate();
  const seasons = show.seasons.filter((season) => season.available_count > 0);
  const [season, setSeason] = useState(seasons.find((candidate) => candidate.season_number > 0)?.season_number ?? seasons[0]?.season_number);
  const detail = useQuery({
    ...seasonQuery(show.id, season ?? 0),
    enabled: season !== undefined,
  });
  const next = show.next_up;
  return (
    <>
      <Backdrop images={show.images} title={show.title}>
        {show.overview ? <p className="line-clamp-3 text-xl leading-relaxed text-foreground/90">{show.overview}</p> : null}
        {next ? (
          <button type="button" data-tv data-tv-autofocus data-watch={`/watch/episode/${next.episode_id}`} className={BUTTON} onClick={() => navigate(`/watch/episode/${next.episode_id}`)}>
            <Play className="h-6 w-6 fill-current" aria-hidden />
            {next.started_show ? `Play next: ${next.code}` : `Play ${next.code}`}
          </button>
        ) : null}
      </Backdrop>
      <div className="space-y-6 px-12">
        <div className="flex flex-wrap gap-3">
          {seasons.map((candidate) => (
            <button
              key={candidate.season_number}
              type="button"
              data-tv
              aria-pressed={candidate.season_number === season}
              onClick={() => setSeason(candidate.season_number)}
              className={candidate.season_number === season ? `${BUTTON} bg-foreground/20` : BUTTON}
            >
              {candidate.title}
            </button>
          ))}
        </div>
        <ol className="space-y-3">
          {detail.data?.episodes
            .filter((episode) => episode.available)
            .map((episode) => (
              <li key={episode.id}>
                <button
                  type="button"
                  data-tv
                  data-watch={`/watch/episode/${episode.id}`}
                  onClick={() => navigate(`/watch/episode/${episode.id}`)}
                  className="flex w-full items-center gap-6 rounded-[var(--radius-card)] p-3 text-left focus:bg-surface-raised"
                >
                  <ArtworkImage image={episode.images.still ?? episode.images.thumb} sizes="16rem" className="aspect-video w-64 shrink-0 rounded-[var(--radius-control)]" />
                  <span className="min-w-0">
                    <span className="block text-xl font-semibold">
                      {episode.code} · {episode.title ?? `Episode ${episode.episode_number ?? ""}`}
                    </span>
                    {episode.overview ? <span className="line-clamp-2 block text-lg text-muted">{episode.overview}</span> : null}
                  </span>
                </button>
              </li>
            ))}
        </ol>
      </div>
    </>
  );
}
