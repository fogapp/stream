import { useEffect, useMemo, useRef } from "react";
import { X } from "lucide-react";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { IconButton } from "@/components/ui/IconButton";
import { cn } from "@/lib/cn";
import { mergeGuides } from "@/lib/guideLayout";
import { clockTime } from "@/lib/live";
import type { Guide, GuideStation } from "@/types";

/**
 * What's on now, down the side of a Grid channel (PROPOSAL §7.7): every
 * channel with a program on, by channel number, the one being watched
 * marked. Choosing one changes to it; the panel stays until it's closed.
 */
export function OnNowPanel({
  guide,
  stationId,
  now,
  onChoose,
  onClose,
}: {
  guide: Guide;
  /** The channel on screen. */
  stationId: string | null;
  now: number;
  onChoose: (station: GuideStation) => void;
  onClose: () => void;
}) {
  // The guide's own rows: a program in parts is one program, and filler isn't one.
  const rows = useMemo(() => mergeGuides([guide]), [guide]);
  const onNow = rows
    .flatMap((row) => {
      const airing = row.airings.find((candidate) => Date.parse(candidate.starts_at) <= now && Date.parse(candidate.ends_at) > now);
      return airing ? [{ station: row.station, airing }] : [];
    })
    .sort((a, b) => a.station.number.localeCompare(b.station.number, undefined, { numeric: true }));
  const panel = useRef<HTMLElement>(null);
  useEffect(() => {
    panel.current?.querySelector<HTMLElement>('[aria-current="true"]')?.scrollIntoView({ block: "nearest" });
  }, [stationId]);

  return (
    <aside
      ref={panel}
      aria-label="On now"
      className="absolute inset-y-0 right-0 z-20 flex w-full flex-col border-l border-border bg-surface shadow-xl sm:w-80 sm:bg-surface/95"
    >
      <div className="flex items-center gap-2 border-b border-border px-4 py-3">
        <h2 className="min-w-0 flex-1 truncate font-semibold">On now</h2>
        <IconButton label="Close on now" onClick={onClose}>
          <X className="h-4 w-4" aria-hidden />
        </IconButton>
      </div>
      <div className="flex-1 overflow-y-auto p-2">
        {onNow.length === 0 ? <p className="px-2 py-3 text-sm text-muted">Nothing is on right now.</p> : null}
        <ul className="space-y-1">
          {onNow.map(({ station, airing }) => {
            const current = station.id === stationId;
            const starts = Date.parse(airing.starts_at);
            const through = Math.min(Math.max((now - starts) / (Date.parse(airing.ends_at) - starts), 0), 1);
            return (
              <li key={station.id}>
                <button
                  type="button"
                  aria-current={current || undefined}
                  onClick={() => onChoose(station)}
                  className={cn(
                    "flex w-full gap-3 rounded-[var(--radius-control)] p-2 text-left transition-colors hover:bg-surface-raised",
                    current && "bg-surface-raised ring-1 ring-primary",
                  )}
                >
                  <div className="relative w-28 shrink-0 overflow-hidden rounded-[var(--radius-control)] ring-1 ring-border">
                    <ArtworkImage
                      image={airing.images.still ?? airing.images.backdrop ?? airing.images.poster}
                      sizes="7rem"
                      className="aspect-video"
                      fallback={<span className="px-1 text-center text-xs text-muted">{airing.title}</span>}
                    />
                    {/* How far through its slot it is. */}
                    <div className="absolute inset-x-0 bottom-0 h-1 bg-foreground/25" aria-hidden>
                      <div className="h-full bg-primary" style={{ width: `${Math.round(through * 100)}%` }} />
                    </div>
                  </div>
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-xs uppercase tracking-wide text-muted">
                      <span className="font-mono font-semibold tabular-nums text-foreground">{station.number}</span> {station.call_sign ?? station.name}
                    </p>
                    <p className="line-clamp-2 text-sm font-medium leading-snug">{airing.title}</p>
                    {airing.subtitle ? <p className="truncate text-xs text-muted">{airing.subtitle}</p> : null}
                    <p className="truncate text-xs text-muted">
                      {clockTime(airing.starts_at, guide.time_zone, false)} – {clockTime(airing.ends_at, guide.time_zone)}
                    </p>
                    {current ? <p className="text-xs text-primary">Watching</p> : null}
                  </div>
                </button>
              </li>
            );
          })}
        </ul>
      </div>
    </aside>
  );
}
