import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { searchQuery } from "@/lib/queries";
import { TvCard } from "@/components/tv/TvCard";
import { TvShell } from "@/components/tv/TvShell";

/**
 * Search on the TV (PROPOSAL §7.2, §7.4): the TV's own keyboard in one
 * box, results in rows a remote moves along.
 */
export function TvSearch() {
  const [query, setQuery] = useState("");
  const term = query.trim();
  const results = useQuery({
    ...searchQuery(term),
    enabled: term.length >= 2,
  });
  const found = results.data;
  const nothing = found && !found.movies.length && !found.shows.length && !found.episodes.length && !found.videos.length;

  return (
    <TvShell>
      <div className="space-y-10 px-12 pt-8">
        <input
          data-tv
          data-tv-autofocus
          type="search"
          aria-label="Search"
          placeholder="Search films, shows, episodes and videos"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          className="h-16 w-full max-w-3xl rounded-[var(--radius-card)] border border-border bg-input px-6 text-2xl text-foreground"
        />
        {results.isError ? <p className="text-xl text-negative">Search didn't answer. Try again.</p> : null}
        {nothing ? <p className="text-xl text-muted">Nothing matches “{term}”.</p> : null}
        {found ? (
          <div className="-mx-12 space-y-10">
            <Row title="Films">
              {found.movies.map((movie) => (
                <TvCard key={movie.id} to={`/tv/movie/${movie.id}`} image={movie.images.poster} title={movie.title} detail={movie.year?.toString()} />
              ))}
            </Row>
            <Row title="Shows">
              {found.shows.map((show) => (
                <TvCard key={show.id} to={`/tv/show/${show.id}`} image={show.images.poster} title={show.title} detail={show.year?.toString()} />
              ))}
            </Row>
            <Row title="Episodes">
              {found.episodes.map((episode) => (
                <TvCard
                  key={episode.id}
                  wide
                  to={`/watch/episode/${episode.id}`}
                  image={episode.images.still ?? episode.show?.images.backdrop}
                  title={episode.show?.title ?? episode.code}
                  detail={[episode.code, episode.title].filter(Boolean).join(" · ")}
                />
              ))}
            </Row>
            <Row title="Videos">
              {found.videos.map((video) => (
                <TvCard key={video.id} wide to={`/watch/video/${video.id}`} image={video.images.thumb} title={video.title} detail={video.channel?.title} />
              ))}
            </Row>
          </div>
        ) : null}
      </div>
    </TvShell>
  );
}

function Row({ title, children }: { title: string; children: React.ReactNode[] }) {
  if (children.length === 0) return null;
  return (
    <section aria-label={title} className="space-y-4">
      <h2 className="px-12 text-2xl font-semibold">{title}</h2>
      <div className="scrollbar-none flex gap-6 overflow-x-auto px-12 py-3">{children}</div>
    </section>
  );
}
