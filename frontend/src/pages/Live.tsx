import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useMutation, useQueries, useQueryClient } from "@tanstack/react-query";
import { Link, useNavigate } from "react-router-dom";
import { Eye, EyeOff, Settings2 } from "lucide-react";
import { api } from "@/api/client";
import { AiringDetails } from "@/components/live/AiringDetails";
import { AiringSheet } from "@/components/live/AiringSheet";
import { GuideGrid, type GridSizes } from "@/components/live/GuideGrid";
import { GuidePreview } from "@/components/live/GuidePreview";
import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import { EmptyState, ErrorState, LoadingState } from "@/components/ui/PageState";
import { Segmented } from "@/components/ui/Segmented";
import { useAuth } from "@/hooks/useAuth";
import { BREAKPOINTS, useMediaQuery } from "@/hooks/useMediaQuery";
import { airingAt, CHUNK, chunksCovering, floorTo, HALF_HOUR, mergeGuides, openingTime, xOf, type Focus, type Geometry } from "@/lib/guideLayout";
import { clockSkew, dayStart } from "@/lib/live";
import { notAShortcut } from "@/lib/keys";
import { liveHandoff } from "@/lib/liveHandoff";
import { usePlayback } from "@/hooks/usePlayback";
import { keys } from "@/lib/queryKeys";
import { stationsQuery } from "@/lib/queries";
import type { Airing, Guide, GuideStation } from "@/types";

const HOUR = 3_600_000;
/** How far back the guide goes, and forward (the schedule's three days). */
const BACK = 2 * HOUR;
const AHEAD = 74 * HOUR;
const FILTERS = [
  { key: "all", label: "All channels" },
  { key: "favorites", label: "Favourites" },
] as const;
type Filter = (typeof FILTERS)[number]["key"];

function chunkQuery(chunk: number) {
  const from = new Date(chunk).toISOString();
  const to = new Date(chunk + CHUNK).toISOString();
  return {
    queryKey: keys.live.guide(from, to),
    queryFn: ({ signal }: { signal: AbortSignal }) => api.get<Guide>(`/guide?from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`, { signal }),
    staleTime: 60_000,
  };
}

/**
 * The Grid guide (PROPOSAL §7.7): every channel the profile watches, in
 * a grid of what's on when. The program on now tunes in; anything else
 * opens its sheet — remind me, or watch it now from the start.
 */
export function Live() {
  const { user } = useAuth();
  const admin = user?.role === "admin";
  const navigate = useNavigate();
  // Something playing in the corner: a channel can go in the inset over it.
  const { current, openPip } = usePlayback();
  const queryClient = useQueryClient();
  const wide = useMediaQuery(BREAKPOINTS.md);
  const sizes: GridSizes = wide ? { channelWidth: 132, rowHeight: 64, headerHeight: 36 } : { channelWidth: 96, rowHeight: 56, headerHeight: 32 };
  const [geometry] = useState<Geometry>(() => {
    const start = floorTo(Date.now() - BACK, HALF_HOUR);
    return { start, end: start + BACK + AHEAD, pxPerMinute: 6 };
  });
  const shown: Geometry = useMemo(() => ({ ...geometry, pxPerMinute: wide ? 6 : 4 }), [geometry, wide]);
  const [now, setNow] = useState(Date.now());
  const [range, setRange] = useState<[number, number]>(() => [Date.now() - HOUR, Date.now() + 3 * HOUR]);
  const [held, setFocus] = useState<Focus | null>(null);
  const [chosen, setChosen] = useState<{ station: GuideStation; airing: Airing } | null>(null);
  const [filter, setFilter] = useState<Filter>("all");
  const [managing, setManaging] = useState(false);
  const scroller = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 30_000);
    return () => window.clearInterval(timer);
  }, []);

  // A slice either side of what's in view, so scrolling finds it loaded.
  const chunks = chunksCovering(Math.max(range[0] - HOUR, shown.start), Math.min(range[1] + 3 * HOUR, shown.end));
  const results = useQueries({ queries: chunks.map(chunkQuery) });
  const loaded = results.flatMap((result) => (result.data ? [result.data] : []));
  const first = results[0];
  const guideNow = loaded[0] ? Date.now() + clockSkew(loaded[0].now) : now;
  const timeZone = loaded[0]?.time_zone ?? "UTC";
  const dataKey = results.map((result) => result.dataUpdatedAt).join(",");
  // eslint-disable-next-line react-hooks/exhaustive-deps -- rebuilt when any slice changes
  const allRows = useMemo(() => mergeGuides(loaded), [dataKey]);
  const rows = useMemo(() => (filter === "favorites" ? allRows.filter((row) => row.station.favorite) : allRows), [allRows, filter]);

  // A program in parts is one program once the slice with its first part
  // arrives, under that part's id: the focus stays on it.
  const focus = useMemo(() => {
    const row = held ? rows[held.row] : undefined;
    if (!held || !row || row.airings.some((airing) => airing.id === held.airingId)) return held;
    const same = row.airings.find((airing) => Date.parse(airing.starts_at) <= held.cursor && Date.parse(airing.ends_at) > held.cursor);
    return same ? { ...held, airingId: same.id } : held;
  }, [held, rows]);

  const onVisible = useCallback((from: number, to: number) => {
    setRange((current) => {
      const [chunkFrom, chunkTo] = [floorTo(from, HALF_HOUR), floorTo(to, HALF_HOUR) + HALF_HOUR];
      return current[0] === chunkFrom && current[1] === chunkTo ? current : [chunkFrom, chunkTo];
    });
  }, []);

  const jumpTo = useCallback(
    (time: number, left = floorTo(time, HALF_HOUR)) => {
      const element = scroller.current;
      if (!element) return;
      element.scrollTo({ left: Math.max(xOf(shown, left), 0) });
      setFocus((current) => {
        const row = current?.row ?? 0;
        const target = airingAt(rows[row]?.airings ?? [], Math.max(time, now));
        return { row, airingId: target?.id ?? null, cursor: time };
      });
    },
    [shown, rows, now],
  );

  // Open on the half hour before this one, once the grid is there to scroll — and,
  // back from watching a channel, on that channel, which carries on in the preview.
  const opened = useRef(false);
  useLayoutEffect(() => {
    const element = scroller.current;
    if (opened.current || !element || rows.length === 0) return;
    opened.current = true;
    element.scrollLeft = xOf(shown, openingTime(Date.now()));
    const back = liveHandoff.leftFrom();
    const index = back ? rows.findIndex((row) => row.station.id === back) : -1;
    const row = rows[index];
    if (row) setFocus({ row: index, airingId: airingAt(row.airings, guideNow)?.id ?? null, cursor: guideNow });
  });

  // Typed digits jump to a channel.
  const [entry, setEntry] = useState("");
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (notAShortcut(event) || chosen || managing) return;
      if (/^[0-9.]$/.test(event.key)) setEntry((typed) => (typed + event.key).slice(0, 7));
      else if (event.key === "Home") jumpTo(Date.now());
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [chosen, managing, jumpTo]);
  useEffect(() => {
    if (!entry) return;
    const timer = window.setTimeout(() => {
      const index = rows.findIndex((row) => row.station.number === entry);
      const row = rows[index];
      if (row) {
        const cursor = Math.max(focus?.cursor ?? now, now);
        setFocus({ row: index, airingId: airingAt(row.airings, cursor)?.id ?? null, cursor });
      }
      setEntry("");
    }, 900);
    return () => window.clearTimeout(timer);
  }, [entry, rows, focus, now]);

  const invalidate = () => void queryClient.invalidateQueries({ queryKey: keys.live.all });
  const favorite = useMutation({
    mutationFn: (station: GuideStation) => (station.favorite ? api.delete(`/stations/${station.id}/favorite`) : api.put(`/stations/${station.id}/favorite`)),
    onSuccess: invalidate,
  });
  const hide = useMutation({
    mutationFn: ({ id, hidden }: { id: string; hidden: boolean }) => (hidden ? api.put(`/stations/${id}/hide`) : api.delete(`/stations/${id}/hide`)),
    onSuccess: () => {
      setFocus(null);
      invalidate();
    },
  });
  const remind = useMutation({
    mutationFn: ({ airing, on }: { airing: Airing; on: boolean }) =>
      on ? api.put(`/airings/${airing.id}/reminder`) : api.delete(`/airings/${airing.id}/reminder`),
    onSuccess: (_data, { airing, on }) => {
      setChosen((current) => (current && current.airing.id === airing.id ? { ...current, airing: { ...current.airing, reminded: on } } : current));
      invalidate();
    },
  });

  const choose = useCallback(
    (station: GuideStation, airing: Airing) => {
      const onNow = Date.parse(airing.starts_at) <= guideNow && Date.parse(airing.ends_at) > guideNow;
      if (onNow) {
        const preview = document.querySelector<HTMLElement>("[data-testid=guide-preview]");
        if (preview) preview.dataset.handoff = station.id;
        navigate(`/live/${encodeURIComponent(station.number)}`);
      }
      else setChosen({ station, airing });
    },
    [guideNow, navigate],
  );

  // Stable, so the grid's rows aren't redrawn for it.
  // Held steady: a guide row re-renders only when something about it changes.
  const { mutate: favoriteChannel } = favorite;
  const { mutate: changeHidden } = hide;
  const hideChannel = useCallback((station: GuideStation) => changeHidden({ id: station.id, hidden: true }), [changeHidden]);
  const editChannel = useCallback((station: GuideStation) => navigate(`/live/channels/${station.id}`), [navigate]);

  const focusedRow = focus ? rows[focus.row] : rows[0];
  const focusedAiring = focusedRow
    ? (focusedRow.airings.find((airing) => airing.id === focus?.airingId) ?? airingAt(focusedRow.airings, guideNow))
    : null;
  const today = dayStart(guideNow, timeZone);
  const days = [0, 1, 2].map((offset) => ({
    offset,
    label: offset === 0 ? "Today" : offset === 1 ? "Tomorrow" : new Intl.DateTimeFormat(undefined, { weekday: "long", timeZone }).format(new Date(today + offset * 24 * HOUR + 12 * HOUR)),
  }));

  return (
    <div className="flex h-[calc(100dvh-3.5rem)] flex-col gap-3 px-2 py-3 sm:px-4 lg:h-dvh lg:px-6 lg:py-4">
      <div className="flex flex-wrap items-center gap-2">
        <h1 className="mr-auto text-xl font-semibold">Grid</h1>
        <div className="flex gap-1 overflow-x-auto">
          <Button size="sm" variant="secondary" onClick={() => jumpTo(Date.now(), openingTime(Date.now()))}>
            Now
          </Button>
          <Button size="sm" variant="ghost" onClick={() => jumpTo(today + 20 * HOUR)}>
            Tonight
          </Button>
          {days.slice(1).map((day) => (
            <Button key={day.offset} size="sm" variant="ghost" onClick={() => jumpTo(floorTo(guideNow, HALF_HOUR) + day.offset * 24 * HOUR)}>
              {day.label}
            </Button>
          ))}
        </div>
        <Segmented segments={FILTERS} value={filter} onChange={setFilter} label="Which channels" />
        <Button size="sm" variant="ghost" onClick={() => setManaging(true)} aria-label="Hidden channels">
          <EyeOff className="h-4 w-4" aria-hidden />
          <span className="hidden sm:inline">Hidden</span>
        </Button>
        {admin ? (
          <Link to="/live/channels">
            <Button size="sm" variant="secondary">
              <Settings2 className="h-4 w-4" aria-hidden />
              <span className="hidden sm:inline">Channels</span>
            </Button>
          </Link>
        ) : null}
      </div>

      {first?.isPending ? (
        <LoadingState label="Loading the guide…" />
      ) : first?.isError ? (
        <ErrorState message="The guide couldn't be loaded." onRetry={() => void first.refetch()} />
      ) : allRows.length === 0 ? (
        <EmptyState
          title="No channels yet"
          description={admin ? "Make a channel from shows and films in the library." : "An admin can make channels in Grid › Channels."}
          action={
            admin ? (
              <Link to="/live/channels/new">
                <Button>New channel</Button>
              </Link>
            ) : undefined
          }
        />
      ) : (
        <>
          <div className="min-h-28 rounded-[var(--radius-card)] border border-border bg-surface p-3" aria-live="polite">
            {focusedRow && focusedAiring ? (
              <AiringDetails
                airing={focusedAiring}
                station={focusedRow.station}
                timeZone={timeZone}
                showReason={admin}
                compact
                picture={
                  <GuidePreview
                    sound
                    stationId={focusedRow.station.id}
                    airing={focusedAiring}
                    image={focusedAiring.images.still ?? focusedAiring.images.backdrop ?? focusedAiring.images.poster}
                  />
                }
              />
            ) : (
              <p className="text-sm text-muted">{filter === "favorites" ? "No favourite channels yet — add them from a channel's menu." : "Nothing scheduled here."}</p>
            )}
          </div>
          <GuideGrid
            rows={rows}
            geometry={shown}
            sizes={sizes}
            now={guideNow}
            timeZone={timeZone}
            focus={focus}
            onFocus={setFocus}
            onChoose={choose}
            onFavorite={favoriteChannel}
            onHide={hideChannel}
            onEdit={admin ? editChannel : undefined}
            onVisible={onVisible}
            scroller={scroller}
          />
        </>
      )}

      {entry ? (
        <div className="pointer-events-none fixed right-6 top-6 z-[60] rounded-[var(--radius-card)] bg-surface-raised px-4 py-2 font-mono text-3xl tabular-nums shadow-lg" aria-live="polite">
          {entry}
        </div>
      ) : null}
      {chosen ? (
        <AiringSheet
          airing={chosen.airing}
          station={chosen.station}
          timeZone={timeZone}
          now={guideNow}
          admin={admin}
          onTune={() => navigate(`/live/${encodeURIComponent(chosen.station.number)}`)}
          onPip={
            current
              ? () => {
                  openPip({ kind: "station", stationId: chosen.station.id, number: chosen.station.number, title: chosen.station.name });
                  setChosen(null);
                }
              : undefined
          }
          onRemind={(on) => remind.mutate({ airing: chosen.airing, on })}
          onClose={() => setChosen(null)}
        />
      ) : null}
      {managing ? <HiddenStations onClose={() => setManaging(false)} onUnhide={(id) => hide.mutate({ id, hidden: false })} /> : null}
    </div>
  );
}

/** Channels this profile hid, to bring back. */
function HiddenStations({ onClose, onUnhide }: { onClose: () => void; onUnhide: (id: string) => void }) {
  const [stations] = useQueries({ queries: [stationsQuery(true)] });
  const hidden = (stations.data ?? []).filter((station) => station.hidden);
  return (
    <Dialog label="Hidden channels" onClose={onClose}>
      <h2 className="mb-3 font-semibold">Hidden channels</h2>
      {stations.isPending ? (
        <LoadingState />
      ) : stations.isError ? (
        <ErrorState message="Couldn't load the channels." onRetry={() => void stations.refetch()} />
      ) : hidden.length === 0 ? (
        <p className="text-sm text-muted">None. Hide a channel from its menu in the guide.</p>
      ) : (
        <ul className="space-y-1">
          {hidden.map((station) => (
            <li key={station.id} className="flex items-center gap-3 text-sm">
              <span className="w-12 font-mono tabular-nums">{station.number}</span>
              <span className="flex-1">{station.name}</span>
              <Button variant="ghost" size="sm" onClick={() => onUnhide(station.id)}>
                <Eye className="h-4 w-4" aria-hidden />
                Show again
              </Button>
            </li>
          ))}
        </ul>
      )}
    </Dialog>
  );
}
