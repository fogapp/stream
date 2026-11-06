import { useQuery } from "@tanstack/react-query";
import { useParams } from "react-router-dom";
import { UserRound } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { PosterCard } from "@/components/viewing/cards";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import type { MovieCard, PersonDetail as Person, ShowCard } from "@/types";
import { plural } from "@/lib/format";

const GRID = "grid grid-cols-2 gap-x-3 gap-y-5 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 2xl:grid-cols-8";

/** Someone across every library (PROPOSAL §7.2): what they're in that you can watch. */
export function PersonDetail() {
  const { id = "" } = useParams();
  const person = useQuery({ queryKey: keys.people.detail(id), queryFn: ({ signal }) => api.get<Person>(`/people/${id}`, { signal }) });

  return (
    <div className="space-y-8 px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
      <QueryState query={person} errorMessage="Could not load this person.">
        {(data) => (
          <>
            <header className="flex items-center gap-4">
              <ArtworkImage
                image={data.image}
                sizes="6rem"
                className="aspect-square w-20 shrink-0 rounded-full ring-1 ring-border sm:w-24"
                fallback={<UserRound className="h-8 w-8 text-muted" aria-hidden />}
                eager
              />
              <div className="min-w-0">
                <h1 className="truncate text-2xl font-bold tracking-tight text-foreground sm:text-3xl">{data.name}</h1>
                <p className="text-sm text-muted">
                  {[count(data.movies.length, "movie"), count(data.shows.length, "show")].filter(Boolean).join(" · ") || "Nothing here yet"}
                </p>
              </div>
            </header>
            {data.movies.length + data.shows.length === 0 ? (
              <EmptyState title="Nothing to watch" description="None of the titles they're in are in your libraries." />
            ) : null}
            <Credits title="Movies" items={data.movies} />
            <Credits title="Shows" items={data.shows} />
          </>
        )}
      </QueryState>
    </div>
  );
}

function count(n: number, noun: string): string | null {
  return n === 0 ? null : plural(n, noun);
}

function Credits({ title, items }: { title: string; items: (MovieCard | ShowCard)[] }) {
  if (items.length === 0) return null;
  return (
    <section className="space-y-3">
      <h2 className="text-base font-semibold text-foreground">{title}</h2>
      <div className={GRID}>
        {items.map((item) => (
          <PosterCard key={item.id} item={item} />
        ))}
      </div>
    </section>
  );
}
