import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate, useParams } from "react-router-dom";
import { Check, CircleAlert, Eye, EyeOff, Pencil, Play } from "lucide-react";
import { api } from "@/api/client";
import { formatBytes } from "@/lib/bytes";
import { formatRuntime } from "@/lib/format";
import { keys } from "@/lib/queryKeys";
import { refreshWatched } from "@/lib/watched";
import { CastRow } from "@/components/viewing/CastRow";
import { Extras } from "@/components/viewing/Extras";
import { MoreLikeThis } from "@/components/viewing/MoreLikeThis";
import { ForProfiles } from "@/components/viewing/ForProfiles";
import { HideFromProfile } from "@/components/viewing/HideFromProfile";
import { AddToPlaylist } from "@/components/viewing/AddToPlaylist";
import { WatchLaterButton } from "@/components/viewing/WatchLaterButton";
import { DownloadButton } from "@/components/viewing/DownloadButton";
import { TrailerButton } from "@/components/viewing/TrailerButton";
import { ArtworkPicker } from "@/components/viewing/ArtworkPicker";
import { StarRating } from "@/components/viewing/StarRating";
import { AddToCollection, PartOf } from "@/components/viewing/CollectionLinks";
import { MetadataEditor, MOVIE_FIELDS } from "@/components/viewing/MetadataEditor";
import { useAuth } from "@/hooks/useAuth";
import { Hero } from "@/components/viewing/Hero";
import { PlayButtons } from "@/components/viewing/PlayButton";
import { ProgressBar } from "@/components/ui/ProgressBar";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { QueryState } from "@/components/ui/PageState";
import type { MovieDetail as Movie, Version } from "@/types";

/** A film's page (PROPOSAL §7.2). */
export function MovieDetail() {
  const { id = "" } = useParams();
  const movie = useQuery({ queryKey: keys.movies.detail(id), queryFn: ({ signal }) => api.get<Movie>(`/movies/${id}`, { signal }) });
  return (
    <QueryState query={movie} errorMessage="Could not load this movie.">
      {(detail) => <MoviePage movie={detail} />}
    </QueryState>
  );
}

function MoviePage({ movie }: { movie: Movie }) {
  const queryClient = useQueryClient();
  const toggle = useMutation({
    mutationFn: () => api.post("/watch_states", { playable_type: "movie", playable_id: movie.id, watched: !movie.watched }),
    onSuccess: () => refreshWatched(queryClient, { kind: "movie", id: movie.id, watched: !movie.watched }),
  });
  const playable = movie.versions.some((version) => version.playable);
  const { user } = useAuth();
  const admin = user?.role === "admin";
  const [editing, setEditing] = useState(false);
  const director = movie.cast.filter((member) => member.role === "director").map((member) => member.name);
  const facts = [movie.year, formatRuntime(movie.runtime_minutes), movie.content_rating, movie.genres.slice(0, 3).join(", ")].filter(Boolean);

  return (
    <div className="pb-10">
      <Hero images={movie.images} title={movie.title}>
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-muted">
          {facts.map((fact) => (
            <span key={String(fact)}>{fact}</span>
          ))}
          {movie.watched ? (
            <Badge tone="success">
              <Check className="h-3 w-3" aria-hidden />
              Watched
            </Badge>
          ) : null}
        </div>
        <StarRating kind="movie" id={movie.id} value={movie.my_rating} onChange={() => void queryClient.invalidateQueries({ queryKey: keys.movies.detail(movie.id) })} />
        {movie.progress ? <ProgressBar variant="overlay" value={movie.progress} className="max-w-sm rounded-full" /> : null}
        {movie.tagline ? <p className="text-lg italic text-foreground/90">{movie.tagline}</p> : null}
        {movie.overview ? <p className="max-w-3xl text-sm leading-relaxed text-foreground/90 sm:text-base">{movie.overview}</p> : null}
        {director.length > 0 ? <p className="text-sm text-muted">Directed by {director.join(", ")}</p> : null}
        <PartOf collections={movie.collections} />
        <div className="flex flex-wrap items-center gap-2">
          {playable ? (
            <PlayButtons kind="movie" id={movie.id} resumeAt={movie.resume_at} />
          ) : (
            <p className="flex items-center gap-2 text-sm text-warning">
              <CircleAlert className="h-4 w-4" aria-hidden />
              {movie.versions[0]?.unplayable_reason ?? "No readable file"}
            </p>
          )}
          <Button size="lg" variant="ghost" onClick={() => toggle.mutate()} disabled={toggle.isPending}>
            {movie.watched ? <EyeOff className="h-4 w-4" aria-hidden /> : <Eye className="h-4 w-4" aria-hidden />}
            {movie.watched ? "Mark unwatched" : "Mark watched"}
          </Button>
          {admin ? (
            <Button size="lg" variant="ghost" onClick={() => setEditing((value) => !value)} aria-expanded={editing}>
              <Pencil className="h-4 w-4" aria-hidden />
              Edit details
            </Button>
          ) : null}
          {admin ? <ArtworkPicker ownerType="movie" ownerId={movie.id} /> : null}
          <WatchLaterButton item={{ kind: "movie", id: movie.id, title: movie.title }} />
          <DownloadButton item={{ type: "movie", id: movie.id }} />
          <TrailerButton trailer={movie.trailer} />
          <AddToPlaylist item={{ kind: "movie", id: movie.id }} className="self-center" />
          <ForProfiles item={{ kind: "movie", id: movie.id }} />
          <HideFromProfile item={{ kind: "movie", id: movie.id, title: movie.title }} />
          <AddToCollection
            item={{ kind: "movie", id: movie.id }}
            member={movie.collections}
            onChange={() => void queryClient.invalidateQueries({ queryKey: keys.movies.detail(movie.id) })}
          />
        </div>
      </Hero>
      <div className="space-y-8">
        {editing ? (
          <div className="px-4 sm:px-6 lg:px-8">
            <MetadataEditor
              kind="movie"
              id={movie.id}
              fields={MOVIE_FIELDS}
              values={movie as unknown as Record<string, unknown>}
              locked={movie.locked_fields}
              onSaved={() => {
                setEditing(false);
                void queryClient.invalidateQueries({ queryKey: keys.movies.all });
                void queryClient.invalidateQueries({ queryKey: keys.home.all });
              }}
              onUnlocked={() => void queryClient.invalidateQueries({ queryKey: keys.movies.all })}
              onCancel={() => setEditing(false)}
            />
          </div>
        ) : null}
        <Extras extras={movie.extras} />
        <CastRow cast={movie.cast} />
        <MoreLikeThis kind="movie" id={movie.id} />
        <Versions movieId={movie.id} versions={movie.versions} />
      </div>
    </div>
  );
}

function Versions({ movieId, versions }: { movieId: string; versions: Version[] }) {
  const navigate = useNavigate();
  if (versions.length === 0) return null;
  return (
    <section className="space-y-3 px-4 sm:px-6 lg:px-8">
      <h2 className="text-base font-semibold text-foreground">{versions.length > 1 ? "Versions" : "File"}</h2>
      <ul className="space-y-2">
        {versions.map((version) => (
          <li
            key={version.media_file_id}
            className="flex flex-wrap items-start gap-3 rounded-[var(--radius-card)] border border-border bg-surface px-4 py-3 text-sm"
          >
            <div className="min-w-0 flex-1">
            {version.edition ? <p className="font-medium text-foreground">{version.edition}</p> : null}
            <p className="break-all font-mono text-xs text-muted">{version.filename}</p>
            <p className="mt-1 text-foreground">
              {[version.video, version.audio, version.subtitles ? `${version.subtitles} subtitle tracks` : null, formatBytes(version.size)]
                .filter(Boolean)
                .join(" · ")}
            </p>
            {!version.playable && version.unplayable_reason ? (
              <p className="mt-1 text-xs text-warning">{version.unplayable_reason}</p>
            ) : null}
            </div>
            {versions.length > 1 && version.playable ? (
              <Button
                variant="secondary"
                size="sm"
                aria-label={`Play ${version.edition ?? version.filename}`}
                onClick={() => navigate(`/watch/movie/${movieId}?version=${version.media_file_id}`)}
              >
                <Play className="h-3.5 w-3.5 fill-current" aria-hidden />
                Play
              </Button>
            ) : null}
          </li>
        ))}
      </ul>
    </section>
  );
}
