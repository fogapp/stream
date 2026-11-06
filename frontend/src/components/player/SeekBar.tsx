import { useRef, useState, type PointerEvent } from "react";
import { formatClock } from "@/lib/format";
import type { Chapter, TrickplayInfo } from "@/types";

const PREVIEW_WIDTH = 192;

/**
 * The timeline (PROPOSAL §7.3): played, buffered, chapter boundaries, and
 * on hover a thumbnail of that moment with its time and chapter. Dragging
 * shows where it would land and seeks once, on release
 * (docs/PERF_PROPOSAL.md › P14): a seek per pointer move restarted the
 * transcoder at every one. A slider for assistive tech (arrow keys are the
 * player's own shortcuts).
 */
export function SeekBar({
  current,
  duration,
  buffered,
  chapters = [],
  segments = [],
  trickplay = null,
  onSeek,
}: {
  current: number;
  duration: number;
  buffered: number;
  chapters?: Chapter[];
  /** SponsorBlock spans, marked on the bar. */
  segments?: { start: number; end: number; category: string }[];
  trickplay?: TrickplayInfo | null;
  onSeek: (seconds: number) => void;
}) {
  const bar = useRef<HTMLDivElement>(null);
  const [hover, setHover] = useState<number | null>(null);
  // Where a drag would land, while dragging.
  const [dragAt, setDragAt] = useState<number | null>(null);

  function timeAt(event: PointerEvent) {
    const rect = bar.current?.getBoundingClientRect();
    if (!rect || duration <= 0) return 0;
    return (Math.min(Math.max(event.clientX - rect.left, 0), rect.width) / rect.width) * duration;
  }

  const percent = (value: number) => `${duration > 0 ? Math.min(value / duration, 1) * 100 : 0}%`;
  const position = dragAt ?? current;
  const shown = dragAt ?? hover ?? current;
  const chapter = chapters.find((candidate) => shown >= candidate.start && shown < candidate.end) ?? null;

  return (
    <div
      ref={bar}
      role="slider"
      tabIndex={-1}
      aria-label="Seek"
      aria-valuemin={0}
      aria-valuemax={Math.round(duration)}
      aria-valuenow={Math.round(position)}
      aria-valuetext={`${formatClock(position)} of ${formatClock(duration)}`}
      className="group relative flex h-5 cursor-pointer touch-none items-center"
      onPointerDown={(event) => {
        event.currentTarget.setPointerCapture(event.pointerId);
        setDragAt(timeAt(event));
      }}
      onPointerMove={(event) => {
        setHover(timeAt(event));
        if (dragAt !== null) setDragAt(timeAt(event));
      }}
      onPointerUp={(event) => {
        if (dragAt === null) return;
        setDragAt(null);
        onSeek(timeAt(event));
      }}
      onPointerCancel={() => setDragAt(null)}
      onPointerLeave={() => setHover(null)}
    >
      <div className="relative h-1 w-full overflow-hidden rounded-full bg-foreground/25 transition-[height] group-hover:h-1.5">
        <div className="absolute inset-y-0 left-0 bg-foreground/40" style={{ width: percent(buffered) }} />
        <div className="absolute inset-y-0 left-0 bg-primary" style={{ width: percent(position) }} />
        {segments.map((segment) => (
          <div
            key={`${segment.category}-${segment.start}`}
            className={segment.category === "sponsor" ? "absolute inset-y-0 bg-positive" : "absolute inset-y-0 bg-warning"}
            style={{ left: percent(segment.start), width: `calc(${percent(segment.end)} - ${percent(segment.start)})` }}
          />
        ))}
        {chapters.slice(1).map((mark) => (
          <div key={mark.start} className="absolute inset-y-0 w-0.5 bg-background" style={{ left: percent(mark.start) }} />
        ))}
      </div>
      <div
        className="pointer-events-none absolute h-3.5 w-3.5 -translate-x-1/2 rounded-full bg-primary opacity-0 transition group-hover:opacity-100"
        style={{ left: percent(position) }}
      />
      {hover !== null || dragAt !== null ? (
        <div
          className="pointer-events-none absolute bottom-6 flex -translate-x-1/2 flex-col items-center gap-1"
          style={{ left: `clamp(${PREVIEW_WIDTH / 2}px, ${percent(shown)}, calc(100% - ${PREVIEW_WIDTH / 2}px))` }}
        >
          {trickplay ? <Thumbnail trickplay={trickplay} seconds={shown} /> : null}
          <div className="max-w-60 truncate rounded bg-background/90 px-1.5 py-0.5 text-center text-xs text-foreground">
            <span className="font-mono tabular-nums">{formatClock(shown)}</span>
            {chapter?.title ? <span className="text-muted"> · {chapter.title}</span> : null}
          </div>
        </div>
      ) : null}
    </div>
  );
}

/** One tile of a sprite sheet, scaled to the preview width. */
function Thumbnail({ trickplay, seconds }: { trickplay: TrickplayInfo; seconds: number }) {
  const perSheet = trickplay.columns * trickplay.rows;
  const index = Math.min(Math.max(Math.floor(seconds / trickplay.interval), 0), trickplay.count - 1);
  const sheet = Math.floor(index / perSheet);
  const within = index % perSheet;
  const scale = PREVIEW_WIDTH / trickplay.tile_width;
  const height = Math.round(trickplay.tile_height * scale);
  return (
    <div
      className="rounded-[var(--radius-control)] ring-2 ring-foreground/80"
      style={{
        width: PREVIEW_WIDTH,
        height,
        backgroundImage: `url(${trickplay.sheet_url.replace("{index}", String(sheet))})`,
        backgroundSize: `${trickplay.columns * PREVIEW_WIDTH}px ${trickplay.rows * height}px`,
        backgroundPosition: `-${(within % trickplay.columns) * PREVIEW_WIDTH}px -${Math.floor(within / trickplay.columns) * height}px`,
      }}
    />
  );
}
