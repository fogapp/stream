import { lazy, Suspense, useEffect, useState } from "react";
import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { Link, useParams, useSearchParams } from "react-router-dom";
import { Search, UserRound } from "lucide-react";
import { api } from "@/api/client";
import { useDebouncedValue } from "@/hooks/useDebouncedValue";
import { useAuth } from "@/hooks/useAuth";
import { ChannelLibrary } from "@/components/youtube/ChannelLibrary";
import { HomeVideosTimeline } from "@/components/viewing/HomeVideosTimeline";
import { LiveLibrary } from "@/components/viewing/LiveLibrary";
import { ForProfiles } from "@/components/viewing/ForProfiles";

import { cn } from "@/lib/cn";
import { keys } from "@/lib/queryKeys";
import { librariesQuery } from "@/lib/queries";
import { PosterCard } from "@/components/viewing/cards";
import { AlphabetRail } from "@/components/viewing/AlphabetRail";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { LoadMore } from "@/components/ui/LoadMore";
import { Input } from "@/components/ui/Input";
import { EmptyState, ErrorState, LoadingState, QueryState } from "@/components/ui/PageState";
import { Segmented } from "@/components/ui/Segmented";
import { Select } from "@/components/ui/Select";
import { Toggle } from "@/components/ui/Toggle";
import type { ClipFilters, ClipPlace, LetterStart, Library as LibraryInfo, MovieCard, ShowCard } from "@/types";

// Leaflet and its tiles only for someone who opens the map.
const PlacesMap = lazy(() => import("@/components/viewing/PlacesMap"));

const PAGE = 120;
const SORTS = [
  { key: "title", label: "A–Z" },
  { key: "added", label: "Recently added" },
  { key: "year", label: "Year" },
  { key: "rating", label: "Rating" },
] as const;
type Sort = (typeof SORTS)[number]["key"];

const FILTERS = [
  { key: "all", label: "All" },
  { key: "unwatched", label: "Unwatched" },
] as const;
type Filter = (typeof FILTERS)[number]["key"];

function isSort(value: string | null): value is Sort {
  return SORTS.some((sort) => sort.key === value);
}

/** A library's poster wall (PROPOSAL §7.2). Sort and filter live in the URL. */
export function Library() {
  const { id = "" } = useParams();
  const library = useQuery(librariesQuery());
  return (
    <QueryState query={library} errorMessage="Could not load this library.">
      {(list) => {
        const found = list.find((candidate) => candidate.id === id);
        if (!found) return <EmptyState title="No such library" />;
        if (found.kind === "home_videos") return <HomeVideosPage key={found.id} library={found} />;
        if (found.kind === "live") return <LiveLibrary key={found.id} library={found} />;
        return found.kind === "channels" ? <ChannelLibrary key={found.id} library={found} /> : <LibraryGrid key={found.id} library={found} />;
      }}
    </QueryState>
  );
}

function LibraryGrid({ library }: { library: LibraryInfo }) {
  const [params, setParams] = useSearchParams();
  const sort: Sort = isSort(params.get("sort")) ? (params.get("sort") as Sort) : "title";
  const filter: Filter = params.get("filter") === "unwatched" ? "unwatched" : "all";
  const [query, setQuery] = useState("");
  const q = useDebouncedValue(query.trim(), 250);
  const endpoint = library.kind === "movies" ? "/movies" : "/shows";
  const filters = { library_id: library.id, sort, unwatched: filter === "unwatched", q };

  const items = useInfiniteQuery({
    queryKey: library.kind === "movies" ? keys.movies.list(filters) : keys.shows.list(filters),
    queryFn: ({ pageParam, signal }) => {
      const search = new URLSearchParams({ library_id: library.id, sort, page: String(pageParam), per: String(PAGE) });
      if (filters.unwatched) search.set("unwatched", "true");
      if (q) search.set("q", q);
      return api.get<(MovieCard | ShowCard)[]>(`${endpoint}?${search.toString()}`, { signal });
    },
    initialPageParam: 1,
    getNextPageParam: (last, pages) => (last.length === PAGE ? pages.length + 1 : undefined),
  });
  // Where each letter starts, for the alphabet beside an A–Z grid.
  const letterFilters = { library_id: library.id, unwatched: filters.unwatched, q };
  const letters = useQuery({
    queryKey: library.kind === "movies" ? keys.movies.letters(letterFilters) : keys.shows.letters(letterFilters),
    queryFn: ({ signal }) => {
      const search = new URLSearchParams({ library_id: library.id });
      if (filters.unwatched) search.set("unwatched", "true");
      if (q) search.set("q", q);
      return api.get<LetterStart[]>(`${endpoint}/letters?${search.toString()}`, { signal });
    },
    enabled: sort === "title",
  });

  function update(key: string, value: string, fallback: string) {
    const next = new URLSearchParams(params);
    if (value === fallback) next.delete(key);
    else next.set(key, value);
    setParams(next, { replace: true });
  }

  const cards = items.data?.pages.flat() ?? [];
  const rail = sort === "title" && cards.length > 0 && (letters.data?.length ?? 0) > 1;
  // The rail's gutter is kept from the start of an A–Z wall, not added when
  // the letters answer: added late, it narrowed a grid already drawn and
  // every poster moved (the page's layout shift).
  const railGutter = sort === "title";

  // A letter beyond what's loaded loads pages until its first title is in
  // the grid, then scrolls to it.
  const [target, setTarget] = useState<number | null>(null);
  const { hasNextPage, isFetchingNextPage, isFetchNextPageError, fetchNextPage } = items;
  useEffect(() => {
    if (target === null) return;
    if (target < cards.length) {
      document.querySelector(`[data-index="${target}"]`)?.scrollIntoView({ block: "start" });
      setTarget(null);
    } else if (!hasNextPage || isFetchNextPageError) {
      setTarget(null);
    } else if (!isFetchingNextPage) {
      void fetchNextPage();
    }
  }, [target, cards.length, hasNextPage, isFetchingNextPage, isFetchNextPageError, fetchNextPage]);

  return (
    <div className={cn("space-y-6 px-4 py-6 sm:px-6 lg:px-8 lg:py-8", railGutter && "pr-8 sm:pr-10 lg:pr-12")}>
      <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <div className="flex items-baseline gap-4">
          <h1 className="text-2xl font-bold text-foreground">{library.name}</h1>
          <Link to={`/collections?library=${library.id}`} className="text-sm text-primary hover:underline">
            Collections
          </Link>
        </div>
        <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
          <Input
            aria-label={`Search ${library.name}`}
            placeholder="Search"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            icon={<Search className="h-4 w-4" aria-hidden />}
          />
          <Segmented segments={FILTERS} value={filter} onChange={(key) => update("filter", key, "all")} label="Filter" />
          <Segmented segments={SORTS} value={sort} onChange={(key) => update("sort", key, "title")} label="Sort" />
        </div>
      </div>
      {items.isPending ? (
        <LoadingState />
      ) : items.isError ? (
        <ErrorState message="Could not load titles." onRetry={() => void items.refetch()} />
      ) : cards.length === 0 ? (
        <EmptyState
          title={q || filter === "unwatched" ? "Nothing matches" : "Nothing here yet"}
          description={
            q || filter === "unwatched"
              ? "Try another search or show everything."
              : "Files show up as soon as they're read. Check Settings › Libraries if a scan is stuck."
          }
        />
      ) : (
        <>
          <div className="grid grid-cols-2 gap-x-3 gap-y-5 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 2xl:grid-cols-8">
            {cards.map((card, index) => (
              // Off-screen cards skip layout and paint until they're near: a
              // jump down the alphabet can load thousands.
              <div key={card.id} data-index={index} className="min-w-0 scroll-mt-20 [contain-intrinsic-size:auto_22rem] [content-visibility:auto] lg:scroll-mt-8">
                <PosterCard item={card} />
              </div>
            ))}
          </div>
          <LoadMore
            hasMore={items.hasNextPage}
            loading={items.isFetchingNextPage}
            failed={items.isFetchNextPageError}
            onLoad={() => void items.fetchNextPage()}
          />
          {rail && letters.data ? <AlphabetRail starts={letters.data} onJump={setTarget} /> : null}
        </>
      )}
    </div>
  );
}

/** A home-videos library: its clips through time (PROPOSAL §5.4). */
function HomeVideosPage({ library }: { library: LibraryInfo }) {
  const [params, setParams] = useSearchParams();
  const filters = {
    album_id: params.get("album") ?? undefined,
    person_id: params.get("person") ?? undefined,
    favorites: params.get("favorites") === "true" || undefined,
  };
  const options = useQuery({
    queryKey: keys.clips.filters(library.id),
    queryFn: ({ signal }) => api.get<ClipFilters>(`/clips/filters?library_id=${library.id}`, { signal }),
  });
  const set = (key: string, value: string | null) => {
    const next = new URLSearchParams(params);
    if (value) next.set(key, value);
    else next.delete(key);
    setParams(next, { replace: true });
  };
  const albums = options.data?.albums ?? [];
  const people = options.data?.people ?? [];
  const { user } = useAuth();
  const view = params.get("view") === "map" ? "map" : "timeline";
  const places = useQuery({
    queryKey: keys.clips.places(library.id),
    queryFn: ({ signal }) => api.get<ClipPlace[]>(`/clips/places?library_id=${library.id}`, { signal }),
  });

  return (
    <div className="space-y-6 px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
      <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <h1 className="text-2xl font-bold text-foreground">{library.name}</h1>
        <div className="flex flex-wrap items-center gap-2">
          {albums.length > 0 ? (
            <Select aria-label="Album" value={filters.album_id ?? ""} onChange={(event) => set("album", event.target.value || null)}>
              <option value="">All albums</option>
              {albums.map((album) => (
                <option key={album.id} value={album.id}>
                  {album.title} ({album.count})
                </option>
              ))}
            </Select>
          ) : null}
          {filters.album_id && user?.role === "admin" ? <ForProfiles item={{ kind: "album", id: filters.album_id }} align="right" /> : null}
          {(options.data?.favorites ?? 0) > 0 ? (
            <Toggle label="Favourites" checked={Boolean(filters.favorites)} onChange={(value) => set("favorites", value ? "true" : null)} />
          ) : null}
          {(places.data?.length ?? 0) > 0 ? (
            <Segmented
              segments={[
                { key: "timeline", label: "Timeline" },
                { key: "map", label: "Map" },
              ]}
              value={view}
              onChange={(key) => set("view", key === "map" ? "map" : null)}
              label="View"
            />
          ) : null}
        </div>
      </div>
      {people.length > 0 ? (
        <div role="group" aria-label="People" className="scrollbar-none -mx-4 flex gap-3 overflow-x-auto px-4 sm:-mx-6 sm:px-6 lg:-mx-8 lg:px-8">
          {people.map((person) => {
            const active = filters.person_id === person.id;
            return (
              <button
                key={person.id}
                type="button"
                aria-pressed={active}
                onClick={() => set("person", active ? null : person.id)}
                className="flex w-16 shrink-0 flex-col items-center text-center"
              >
                <ArtworkImage
                  image={person.image}
                  sizes="3.5rem"
                  className={active ? "h-14 w-14 rounded-full ring-2 ring-primary" : "h-14 w-14 rounded-full ring-1 ring-border"}
                  fallback={<UserRound className="h-5 w-5 text-muted" aria-hidden />}
                />
                <span className={active ? "mt-1 w-full truncate text-xs font-medium text-primary" : "mt-1 w-full truncate text-xs text-foreground"}>
                  {person.name}
                </span>
              </button>
            );
          })}
        </div>
      ) : null}
      {view === "map" && places.data ? (
        <Suspense fallback={<LoadingState />}>
          <PlacesMap places={places.data} />
        </Suspense>
      ) : (
        <HomeVideosTimeline key={JSON.stringify(filters)} library={library} filters={filters} />
      )}
    </div>
  );
}
