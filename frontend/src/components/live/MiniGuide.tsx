import { useMemo, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { GuideGrid } from "@/components/live/GuideGrid";
import { Button } from "@/components/ui/Button";
import { fromTv } from "@/lib/tv";
import { airingAt, floorTo, HALF_HOUR, mergeGuides, type Focus, type Geometry } from "@/lib/guideLayout";
import type { Airing, Guide, GuideStation } from "@/types";

const HOUR = 3_600_000;

/**
 * The guide over the picture (PROPOSAL §7.7): the next few hours of every
 * channel in a strip along the bottom, starting on the one being watched,
 * so browsing never stops what's on.
 */
export function MiniGuide({
  guide,
  stationId,
  now,
  onChoose,
  onClose,
}: {
  guide: Guide;
  stationId: string | null;
  now: number;
  onChoose: (station: GuideStation, airing: Airing) => void;
  onClose: () => void;
}) {
  const rows = useMemo(() => mergeGuides([guide]), [guide]);
  const [geometry] = useState<Geometry>(() => {
    const start = floorTo(now, HALF_HOUR);
    return { start, end: start + 3 * HOUR, pxPerMinute: 5 };
  });
  const [focus, setFocus] = useState<Focus | null>(() => {
    const row = Math.max(rows.findIndex((candidate) => candidate.station.id === stationId), 0);
    return { row, airingId: airingAt(rows[row]?.airings ?? [], now)?.id ?? null, cursor: now };
  });
  const scroller = useRef<HTMLDivElement>(null);
  return (
    <div
      className="absolute inset-x-0 bottom-0 z-20 flex h-[55%] flex-col gap-2 bg-background/95 p-3 sm:p-4"
      role="dialog"
      aria-label="Guide"
      onKeyDown={(event) => {
        if (event.key === "Escape" || event.key === "g") {
          event.preventDefault();
          event.stopPropagation();
          onClose();
        }
      }}
    >
      <div className="flex items-center gap-2">
        <p className="mr-auto text-sm font-medium">What's on</p>
        <Link to={fromTv() ? "/tv/live" : "/live"}>
          <Button size="sm" variant="ghost">
            Full guide
          </Button>
        </Link>
        <Button size="sm" variant="secondary" onClick={onClose}>
          Close
        </Button>
      </div>
      <GuideGrid
        rows={rows}
        geometry={geometry}
        sizes={{ channelWidth: 112, rowHeight: 52, headerHeight: 30 }}
        now={now}
        timeZone={guide.time_zone}
        focus={focus}
        onFocus={setFocus}
        onChoose={onChoose}
        onFavorite={() => undefined}
        onHide={() => undefined}
        onVisible={() => undefined}
        scroller={scroller}
        autoFocus
        menus={false}
      />
    </div>
  );
}
