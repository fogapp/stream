import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useParams, useSearchParams } from "react-router-dom";
import { Check, Eye, Info, Pencil, Play, Layers } from "lucide-react";
import { api } from "@/api/client";
import { formatRuntime } from "@/lib/format";
import { MEDIA_FILE_STATE_LABELS } from "@/lib/libraries";
import { keys } from "@/lib/queryKeys";
import { refreshWatched } from "@/lib/watched";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { CastRow } from "@/components/viewing/CastRow";
import { Extras } from "@/components/viewing/Extras";
import { MoreLikeThis } from "@/components/viewing/MoreLikeThis";
import { ForProfiles } from "@/components/viewing/ForProfiles";
import { DownloadButton } from "@/components/viewing/DownloadButton";
import { Menu } from "@/components/ui/Menu";
import { ItemActions } from "@/components/viewing/ItemActions";
import { AddToPlaylist } from "@/components/viewing/AddToPlaylist";
import { StarRating } from "@/components/viewing/StarRating";
import { AddToCollection, PartOf } from "@/components/viewing/CollectionLinks";
import { Hero } from "@/components/viewing/Hero";
import { EPISODE_FIELDS, MetadataEditor, SHOW_FIELDS } from "@/components/viewing/MetadataEditor";
import { useAuth } from "@/hooks/useAuth";
import { PlayButtons } from "@/components/viewing/PlayButton";
import { ShowActions } from "@/components/viewing/ShowActions";
import { ShuffleShow } from "@/components/viewing/ShuffleShow";
import { ProgressBar } from "@/components/ui/ProgressBar";
import { Button } from "@/components/ui/Button";
import { IconButton } from "@/components/ui/IconButton";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import { Tabs } from "@/components/ui/Tabs";
import type { SeasonDetail, SeasonEpisode, ShowDetail as Show } from "@/types";

/** A show's page: Play next, seasons, episodes (PROPOSAL §7.2). */
export function ShowDetail() {
  const { id = "" } = useParams();
  const show = useQuery({ queryKey: keys.shows.detail(id), queryFn: ({ signal }) => api.get<Show>(`/shows/${id}`, { signal }) });
  return (
    <QueryState query={show} errorMessage="Could not load this show.">
      {(detail) => <ShowPage show={detail} />}
    </QueryState>
  );
}

function ShowPage({ show }: { show: Show }) {
  const [params, setParams] = useSearchParams();
  const queryClient = useQueryClient();
  const seasons = show.seasons.filter((season) => season.available_count > 0);
  const regular = seasons.filter((season) => season.season_number > 0);
  const fallback = (regular[0] ?? seasons[0])?.season_number;
  const requested = Number(params.get("season"));
  const active = seasons.some((season) => season.season_number === requested) ? requested : fallback;
  const markAll = useMutation({
    mutationFn: () => api.post(`/shows/${show.id}/watched`, { watched: true }),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: keys.shows.all }),
  });
  const facts = [show.year, show.network, show.content_rating, show.genres.slice(0, 3).join(", ")].filter(Boolean);
  const next = show.next_up;
  const [editing, setEditing] = useState(false);

  return (
    <div className="pb-10">
      <Hero images={show.images} title={show.title}>
        <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-muted">
          {facts.map((fact) => (
            <span key={String(fact)}>{fact}</span>
          ))}
          {show.status ? <span>{show.status}</span> : null}
        </div>
        <StarRating kind="show" id={show.id} value={show.my_rating} onChange={() => void queryClient.invalidateQueries({ queryKey: keys.shows.detail(show.id) })} />
        {show.overview ? <p className="max-w-3xl text-sm leading-relaxed text-foreground/90 sm:text-base">{show.overview}</p> : null}
        <PartOf collections={show.collections} />
        <div className="flex flex-wrap items-center gap-2">
          {next ? (
            <PlayButtons
              kind="episode"
              id={next.episode_id}
              resumeAt={next.resume_at}
              label={next.started_show ? `Play next: ${next.code}` : `Play ${next.code}`}
            />
          ) : null}
          <ForProfiles item={{ kind: "show", id: show.id }} />
          <AddToCollection
            item={{ kind: "show", id: show.id }}
            member={show.collections}
            onChange={() => void queryClient.invalidateQueries({ queryKey: keys.shows.detail(show.id) })}
          />
          <ShowActions show={show} editing={editing} onEdit={() => setEditing((value) => !value)} />
          <ShuffleShow show={show} />
          {show.unwatched_count > 0 ? (
            <Button size="lg" variant="ghost" onClick={() => markAll.mutate()} disabled={markAll.isPending}>
              <Eye className="h-4 w-4" aria-hidden />
              Mark all watched
            </Button>
          ) : null}
        </div>
      </Hero>
      <div className="space-y-8">
        {editing ? (
          <div className="px-4 sm:px-6 lg:px-8">
            <MetadataEditor
              kind="show"
              id={show.id}
              fields={SHOW_FIELDS}
              values={show as unknown as Record<string, unknown>}
              locked={show.locked_fields}
              onSaved={() => {
                setEditing(false);
                void queryClient.invalidateQueries({ queryKey: keys.shows.all });
              }}
              onUnlocked={() => void queryClient.invalidateQueries({ queryKey: keys.shows.all })}
              onCancel={() => setEditing(false)}
            />
          </div>
        ) : null}
        {active === undefined ? (
          <EmptyState title="No episodes yet" description="Episodes show up here as soon as their files are read." />
        ) : (
          <section className="space-y-4">
            <div className="border-b border-border px-4 sm:px-6 lg:px-8">
              <Tabs
                tabs={seasons.map((season) => ({ key: String(season.season_number), label: season.title }))}
                active={String(active)}
                onChange={(key) => setParams({ season: key }, { replace: true })}
                label="Seasons"
              />
            </div>
            <Season showId={show.id} number={active} />
          </section>
        )}
        <Extras extras={show.extras} />
        <CastRow cast={show.cast} />
        <MoreLikeThis kind="show" id={show.id} />
      </div>
    </div>
  );
}

function Season({ showId, number }: { showId: string; number: number }) {
  const season = useQuery({
    queryKey: keys.shows.season(showId, number),
    queryFn: ({ signal }) => api.get<SeasonDetail>(`/shows/${showId}/seasons/${number}`, { signal }),
  });
  return (
    <QueryState query={season} errorMessage="Could not load this season.">
      {(detail) => (
        <ol className="space-y-2 px-4 sm:px-6 lg:px-8">
          {detail.episodes.map((episode) => (
            <EpisodeRow key={episode.id} episode={episode} />
          ))}
        </ol>
      )}
    </QueryState>
  );
}

function EpisodeRow({ episode }: { episode: SeasonEpisode }) {
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const [editing, setEditing] = useState(false);
  const toggle = useMutation({
    mutationFn: () => api.post("/watch_states", { playable_type: "episode", playable_id: episode.id, watched: !episode.watched }),
    onSuccess: () => refreshWatched(queryClient),
  });
  const image = episode.images.still ?? episode.images.thumb;
  const meta = [episode.air_date ? new Date(episode.air_date).toLocaleDateString() : null, formatRuntime(episode.runtime_minutes)]
    .filter(Boolean)
    .join(" · ");

  const artwork = (
    <div className="relative w-36 shrink-0 sm:w-52">
      <ArtworkImage
        image={image}
        sizes="(min-width: 640px) 13rem, 9rem"
        className="aspect-video rounded-[var(--radius-control)] ring-1 ring-border"
        fallback={<span className="text-xs text-muted">{episode.code}</span>}
      />
      {episode.available ? (
        <span className="absolute inset-0 flex items-center justify-center opacity-0 transition group-hover:opacity-100">
          <span className="rounded-full bg-background/80 p-2 text-foreground">
            <Play className="h-4 w-4 fill-current" aria-hidden />
          </span>
        </span>
      ) : null}
      {episode.progress ? (
        <ProgressBar variant="overlay" value={episode.progress} className="absolute inset-x-0 bottom-0 overflow-hidden rounded-b-[var(--radius-control)]" />
      ) : null}
    </div>
  );

  return (
    <li className={episode.available ? "group" : "opacity-60"}>
      <div className="flex gap-3 rounded-[var(--radius-card)] p-2 hover:bg-surface sm:gap-4">
        {episode.available ? (
          <div className="relative shrink-0">
            <Link to={`/watch/episode/${episode.id}`} aria-label={`Play ${episode.code}`}>
              {artwork}
            </Link>
            <ItemActions item={{ ...episode, show: null }} className="absolute bottom-1.5 right-1.5" />
          </div>
        ) : (
          artwork
        )}
        <div className="min-w-0 flex-1 space-y-1">
          <div className="flex items-start justify-between gap-2">
            <p className="font-medium text-foreground">
              <span className="text-muted">{episode.episode_number ?? episode.code}.</span>{" "}
              {episode.title ?? (episode.episode_number ? `Episode ${episode.episode_number}` : episode.code)}
            </p>
            <div className="flex shrink-0 gap-1">
              {episode.versions.length > 1 ? (
                <Menu label={`Versions of ${episode.code}`} icon={<Layers className="h-4 w-4" aria-hidden />} align="right">
                  <div className="space-y-1">
                    {episode.versions.map((version) => (
                      <Link
                        key={version.media_file_id}
                        to={`/watch/episode/${episode.id}?version=${version.media_file_id}`}
                        className="block rounded-[var(--radius-control)] px-2 py-1.5 text-sm text-foreground hover:bg-surface"
                      >
                        {version.edition ?? version.video ?? version.filename}
                        <span className="block text-xs text-muted">{[version.video, version.audio].filter(Boolean).join(" · ")}</span>
                      </Link>
                    ))}
                  </div>
                </Menu>
              ) : null}
              {episode.available ? <AddToPlaylist item={{ kind: "episode", id: episode.id }} align="right" /> : null}
              {episode.available ? <DownloadButton item={{ type: "episode", id: episode.id }} compact /> : null}
              {episode.files && episode.files.length > 0 ? (
                <Menu label={`Files of ${episode.code}`} icon={<Info className="h-4 w-4" aria-hidden />} align="right">
                  <div className="space-y-1">
                    {episode.files.map((file) => (
                      <Link
                        key={file.id}
                        to={`/files/${file.id}`}
                        className="block rounded-[var(--radius-control)] px-2 py-1.5 hover:bg-surface"
                      >
                        <span className="block break-all font-mono text-xs text-foreground">{file.path}</span>
                        <span className="block text-xs text-muted">
                          {[file.edition, MEDIA_FILE_STATE_LABELS[file.state]].filter(Boolean).join(" · ")}
                        </span>
                      </Link>
                    ))}
                  </div>
                </Menu>
              ) : null}
              {user?.role === "admin" ? (
                <IconButton label={`Edit ${episode.code}`} onClick={() => setEditing((value) => !value)} aria-expanded={editing}>
                  <Pencil className="h-4 w-4 text-muted" aria-hidden />
                </IconButton>
              ) : null}
              {episode.available ? (
                <IconButton label={episode.watched ? "Mark unwatched" : "Mark watched"} onClick={() => toggle.mutate()}>
                  <Check className={episode.watched ? "h-4 w-4 text-primary" : "h-4 w-4 text-muted"} aria-hidden />
                </IconButton>
              ) : null}
            </div>
          </div>
          {meta ? <p className="text-xs text-muted">{meta}</p> : null}
          {episode.available ? (
            <StarRating kind="episode" id={episode.id} value={episode.my_rating} small onChange={() => void queryClient.invalidateQueries({ queryKey: keys.shows.all })} />
          ) : null}
          {!episode.available ? <p className="text-xs text-muted">Not in your library</p> : null}
          {episode.overview ? <p className="line-clamp-2 text-sm text-muted">{episode.overview}</p> : null}
        </div>
      </div>
      {editing ? (
        <div className="p-2">
          <MetadataEditor
            kind="episode"
            id={episode.id}
            fields={EPISODE_FIELDS}
            values={episode as unknown as Record<string, unknown>}
            locked={episode.locked_fields}
            onSaved={() => {
              setEditing(false);
              void queryClient.invalidateQueries({ queryKey: keys.shows.all });
            }}
            onUnlocked={() => void queryClient.invalidateQueries({ queryKey: keys.shows.all })}
            onCancel={() => setEditing(false)}
          />
        </div>
      ) : null}
    </li>
  );
}
