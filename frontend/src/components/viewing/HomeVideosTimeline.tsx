import { useMemo, useState } from "react";
import { useInfiniteQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { cn } from "@/lib/cn";
import { capturedMonth, formatCaptured } from "@/lib/format";
import { ClipTile } from "@/components/viewing/ClipTile";
import { LoadMore } from "@/components/ui/LoadMore";
import { EmptyState, ErrorState, LoadingState } from "@/components/ui/PageState";
import type { ClipCard, ClipsPage, Library } from "@/types";

const GRID = "grid grid-cols-2 gap-x-3 gap-y-4 sm:grid-cols-3 md:grid-cols-4 xl:grid-cols-5 2xl:grid-cols-6";

/**
 * Home videos by when they were taken (PROPOSAL §5.4): months under years,
 * newest first, with the years down the side to jump through time.
 */
export function HomeVideosTimeline({ library, filters = {} }: { library?: Library; filters?: { album_id?: string; person_id?: string; favorites?: boolean } }) {
  const [from, setFrom] = useState<number | null>(null);
  const query = useInfiniteQuery({
    queryKey: keys.clips.list({ library_id: library?.id, ...filters, from }),
    queryFn: ({ pageParam, signal }) => {
      const search = new URLSearchParams();
      if (library) search.set("library_id", library.id);
      if (filters.album_id) search.set("album_id", filters.album_id);
      if (filters.person_id) search.set("person_id", filters.person_id);
      if (filters.favorites) search.set("favorites", "true");
      if (pageParam) search.set("before", pageParam);
      return api.get<ClipsPage>(`/clips?${search.toString()}`, { signal });
    },
    initialPageParam: from ? `${from + 1}-01-01T00:00:00` : "",
    getNextPageParam: (last) => (last.more ? (last.clips[last.clips.length - 1]?.captured_at ?? undefined) : undefined),
  });

  const clips = useMemo(() => query.data?.pages.flatMap((page) => page.clips) ?? [], [query.data]);
  const years = query.data?.pages[0]?.years ?? [];
  const months = useMemo(() => {
    const groups: { key: string; label: string; year: number; clips: ClipCard[] }[] = [];
    for (const clip of clips) {
      const { year, month } = capturedMonth(clip);
      const key = `${year}-${month}`;
      const last = groups[groups.length - 1];
      if (last?.key === key) last.clips.push(clip);
      else groups.push({ key, year, label: formatCaptured(clip, { month: "long", year: "numeric" }), clips: [clip] });
    }
    return groups;
  }, [clips]);

  if (query.isPending) return <LoadingState />;
  if (query.isError) return <ErrorState message="Could not load home videos." onRetry={() => void query.refetch()} />;
  if (clips.length === 0 && from === null) {
    return <EmptyState title="No home videos yet" description="Clips show up as soon as they're read, placed by when they were taken." />;
  }

  return (
    <div className="flex gap-6">
      <div className="min-w-0 flex-1 space-y-8">
        {months.map((month) => (
          <section key={month.key} aria-label={month.label} className="space-y-3">
            <h2 className="sticky top-14 z-10 bg-background/95 py-1 text-base font-semibold text-foreground backdrop-blur lg:top-0">{month.label}</h2>
            <div className={GRID}>
              {month.clips.map((clip) => (
                <ClipTile key={clip.id} clip={clip} />
              ))}
            </div>
          </section>
        ))}
        <LoadMore
          hasMore={query.hasNextPage}
          loading={query.isFetchingNextPage}
          failed={query.isFetchNextPageError}
          onLoad={() => void query.fetchNextPage()}
          label="Earlier"
        />
      </div>
      {years.length > 1 ? (
        <nav aria-label="Years" className="sticky top-4 hidden h-fit shrink-0 flex-col gap-0.5 self-start sm:flex">
          <button
            type="button"
            onClick={() => setFrom(null)}
            className={cn("rounded px-2 py-0.5 text-right text-xs", from === null ? "font-semibold text-primary" : "text-muted hover:text-foreground")}
          >
            Newest
          </button>
          {years.map(({ year, count }) => (
            <button
              key={year}
              type="button"
              title={`${count} clips`}
              onClick={() => setFrom(year)}
              className={cn("rounded px-2 py-0.5 text-right text-xs tabular-nums", from === year ? "font-semibold text-primary" : "text-muted hover:text-foreground")}
            >
              {year}
            </button>
          ))}
        </nav>
      ) : null}
    </div>
  );
}
