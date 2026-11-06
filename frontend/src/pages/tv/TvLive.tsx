import { useCallback, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "react-router-dom";
import { api } from "@/api/client";
import { AiringDetails } from "@/components/live/AiringDetails";
import { AiringSheet } from "@/components/live/AiringSheet";
import { GuideGrid } from "@/components/live/GuideGrid";
import { GuidePreview } from "@/components/live/GuidePreview";
import { TvShell } from "@/components/tv/TvShell";
import { EmptyState, ErrorState, LoadingState } from "@/components/ui/PageState";
import { airingAt, mergeGuides, openingTime, xOf, type Focus, type Geometry } from "@/lib/guideLayout";
import { clockSkew } from "@/lib/live";
import { liveHandoff } from "@/lib/liveHandoff";
import { useNowGuide } from "@/lib/liveGuide";
import { keys } from "@/lib/queryKeys";
import type { Airing, GuideStation } from "@/types";

const HOUR = 3_600_000;
const NOTHING = () => undefined;

/**
 * Grid on the 10-foot layout (PROPOSAL §7.7): the guide a remote's width
 * apart, the focused channel playing in the corner, OK on what's on to
 * watch it. The next few hours; the full guide lives on the desktop.
 */
export function TvLive() {
  const guide = useNowGuide();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const rows = useMemo(() => (guide.data ? mergeGuides([guide.data]) : []), [guide.data]);
  const [geometry] = useState<Geometry>(() => {
    const start = openingTime(Date.now());
    return { start, end: start + 4.5 * HOUR, pxPerMinute: 9 };
  });
  const now = Date.now() + (guide.data ? clockSkew(guide.data.now, guide.dataUpdatedAt) : 0);
  const [focus, setFocus] = useState<Focus | null>(null);
  const [chosen, setChosen] = useState<{ station: GuideStation; airing: Airing } | null>(null);
  const scroller = useRef<HTMLDivElement>(null);
  const remind = useMutation({
    mutationFn: ({ airing, on }: { airing: Airing; on: boolean }) => (on ? api.put(`/airings/${airing.id}/reminder`) : api.delete(`/airings/${airing.id}/reminder`)),
    onSuccess: (_data, { airing, on }) => {
      setChosen((current) => (current && current.airing.id === airing.id ? { ...current, airing: { ...current.airing, reminded: on } } : current));
      void queryClient.invalidateQueries({ queryKey: keys.live.all });
    },
  });

  const opened = useRef(false);
  useLayoutEffect(() => {
    const element = scroller.current;
    if (opened.current || !element || rows.length === 0) return;
    opened.current = true;
    element.scrollLeft = xOf(geometry, openingTime(Date.now()));
    // Back from watching a channel: on that channel, which carries on in the preview.
    const back = liveHandoff.leftFrom();
    const index = Math.max(back ? rows.findIndex((row) => row.station.id === back) : 0, 0);
    const first = rows[index];
    if (first) setFocus({ row: index, airingId: airingAt(first.airings, Date.now())?.id ?? null, cursor: Date.now() });
  }, [rows, geometry]);

  const choose = useCallback(
    (station: GuideStation, airing: Airing) => {
      if (Date.parse(airing.starts_at) <= now && Date.parse(airing.ends_at) > now) navigate(`/live/${encodeURIComponent(station.number)}`);
      else setChosen({ station, airing });
    },
    [now, navigate],
  );

  const focusedRow = focus ? rows[focus.row] : rows[0];
  const focusedAiring = focusedRow ? (focusedRow.airings.find((airing) => airing.id === focus?.airingId) ?? airingAt(focusedRow.airings, now)) : null;

  return (
    <TvShell ready={rows.length > 0}>
      <div className="flex h-[calc(100dvh-7rem)] flex-col gap-6 px-12 pt-8">
        {!guide.data ? (
          guide.isError ? <ErrorState message="Could not load the guide." onRetry={() => void guide.refetch()} /> : <LoadingState />
        ) : rows.length === 0 ? (
          <EmptyState title="No channels yet" description="An admin makes channels on the desktop, in Grid › Channels." />
        ) : (
          <>
            <div className="min-h-44 text-lg">
              {focusedRow && focusedAiring ? (
                <AiringDetails
                  airing={focusedAiring}
                  station={focusedRow.station}
                  timeZone={guide.data.time_zone}
                  showReason={false}
                  compact
                  picture={
                    <GuidePreview
                      stationId={focusedRow.station.id}
                      airing={focusedAiring}
                      image={focusedAiring.images.still ?? focusedAiring.images.backdrop ?? focusedAiring.images.poster}
                    />
                  }
                />
              ) : null}
            </div>
            <GuideGrid
              rows={rows}
              geometry={geometry}
              sizes={{ channelWidth: 200, rowHeight: 88, headerHeight: 44 }}
              now={now}
              timeZone={guide.data.time_zone}
              focus={focus}
              onFocus={setFocus}
              onChoose={choose}
              onFavorite={NOTHING}
              onHide={NOTHING}
              onVisible={NOTHING}
              scroller={scroller}
              menus={false}
            />
          </>
        )}
      </div>
      {chosen && guide.data ? (
        <AiringSheet
          airing={chosen.airing}
          station={chosen.station}
          timeZone={guide.data.time_zone}
          now={now}
          admin={false}
          onTune={() => navigate(`/live/${encodeURIComponent(chosen.station.number)}`)}
          onRemind={(on) => remind.mutate({ airing: chosen.airing, on })}
          onClose={() => setChosen(null)}
        />
      ) : null}
    </TvShell>
  );
}
