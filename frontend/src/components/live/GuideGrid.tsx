import { memo, useCallback, useEffect, useLayoutEffect, useRef, useState, type RefObject } from "react";
import { Bell, ChevronLeft, EyeOff, Pencil, Star } from "lucide-react";
import { ActionMenu, ActionMenuItem } from "@/components/ui/ActionMenu";
import { cn } from "@/lib/cn";
import { clockTime } from "@/lib/live";
import { airingAt, floorTo, HALF_HOUR, halfHours, MINUTE, moveFocus, timeOf, xOf, type Focus, type Geometry, type GuideRow, type Move } from "@/lib/guideLayout";
import type { Airing, GuideStation } from "@/types";

export interface GridSizes {
  channelWidth: number;
  rowHeight: number;
  headerHeight: number;
}

/** Rows and minutes drawn beyond the edges, so scrolling never shows a blank. */
const OVERSCAN_ROWS = 4;
const OVERSCAN_MINUTES = 90;
/** How finely the left edge is known to a row: enough for its "started earlier" mark, without a render per scrolled pixel. */
const EDGE_STEP = 5 * MINUTE;

const KEYS: Record<string, Move> = {
  ArrowLeft: "left",
  ArrowRight: "right",
  ArrowUp: "up",
  ArrowDown: "down",
  PageUp: "pageUp",
  PageDown: "pageDown",
};

/**
 * The guide's grid (PROPOSAL §7.7): channels down a column that stays put,
 * half hours across a header that stays put, programs as wide as they are
 * long, and a line at now. Only what's near the view is drawn. One program
 * holds focus at a time (a roving tab stop); the arrow keys move it the way
 * a TV guide's do, and pressing a channel moves it to what that channel has
 * on now.
 */
export function GuideGrid({
  rows,
  geometry,
  sizes,
  now,
  timeZone,
  focus,
  onFocus,
  onChoose,
  onFavorite,
  onHide,
  onEdit,
  onVisible,
  scroller,
  autoFocus = false,
  menus = true,
}: {
  rows: GuideRow[];
  geometry: Geometry;
  sizes: GridSizes;
  now: number;
  timeZone: string;
  focus: Focus | null;
  onFocus: (focus: Focus) => void;
  onChoose: (station: GuideStation, airing: Airing) => void;
  onFavorite: (station: GuideStation) => void;
  onHide: (station: GuideStation) => void;
  /** Offered in each channel's menu to whoever may change channels. */
  onEdit?: (station: GuideStation) => void;
  /** The moments in view, as the grid scrolls. */
  onVisible: (from: number, to: number) => void;
  scroller: RefObject<HTMLDivElement | null>;
  /** Take the keyboard as soon as it's shown. */
  autoFocus?: boolean;
  /** Each channel's favourite/hide menu. */
  menus?: boolean;
}) {
  const [view, setView] = useState({ left: 0, top: 0, width: 1200, height: 800 });
  const cells = useRef(new Map<string, HTMLDivElement>());
  const frame = useRef<number | undefined>(undefined);
  const { channelWidth, rowHeight, headerHeight } = sizes;
  const timelineWidth = xOf(geometry, geometry.end);

  const measure = useCallback(() => {
    const element = scroller.current;
    if (!element) return;
    setView({ left: element.scrollLeft, top: element.scrollTop, width: element.clientWidth, height: element.clientHeight });
  }, [scroller]);

  useLayoutEffect(() => {
    measure();
    const element = scroller.current;
    if (!element) return;
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, [measure, scroller]);

  const visibleFrom = timeOf(geometry, view.left);
  const visibleTo = timeOf(geometry, view.left + view.width - channelWidth);
  useEffect(() => onVisible(visibleFrom, visibleTo), [visibleFrom, visibleTo, onVisible]);

  // On half hours, outwards: scrolling re-renders the rows only as what's
  // drawn changes, not on every frame.
  const drawFrom = floorTo(visibleFrom - OVERSCAN_MINUTES * MINUTE, HALF_HOUR);
  const drawTo = floorTo(visibleTo + OVERSCAN_MINUTES * MINUTE, HALF_HOUR) + HALF_HOUR;
  const firstRow = Math.max(Math.floor((view.top - headerHeight) / rowHeight) - OVERSCAN_ROWS, 0);
  const lastRow = Math.min(Math.ceil((view.top + view.height) / rowHeight) + OVERSCAN_ROWS, rows.length - 1);

  // Keep the focused program in view, and hold the focus on it.
  const focusedId = focus?.airingId ?? null;
  const focusedRow = focus?.row ?? -1;
  useEffect(() => {
    const element = scroller.current;
    const current = rows[focusedRow];
    const airing = current?.airings.find((candidate) => candidate.id === focusedId);
    if (!element || !airing) return;
    const start = xOf(geometry, Math.max(Date.parse(airing.starts_at), geometry.start));
    const end = xOf(geometry, Date.parse(airing.ends_at));
    const room = element.clientWidth - channelWidth;
    // Only when it's out of sight: a long program begun earlier keeps its
    // title in view on its own.
    let left = element.scrollLeft;
    if (end <= left + 24 || start >= left + room - 24) left = Math.max(start - 24, 0);
    const top = headerHeight + focusedRow * rowHeight;
    let scrollTop = element.scrollTop;
    if (top - headerHeight < scrollTop) scrollTop = top - headerHeight;
    else if (top + rowHeight > scrollTop + element.clientHeight) scrollTop = top + rowHeight - element.clientHeight;
    if (left !== element.scrollLeft || scrollTop !== element.scrollTop) element.scrollTo({ left, top: scrollTop });
    const cell = cells.current.get(airing.id);
    if (cell && element.contains(document.activeElement) && document.activeElement !== cell) cell.focus({ preventScroll: true });
  }, [focusedId, focusedRow, rows, geometry, channelWidth, headerHeight, rowHeight, scroller]);

  useEffect(() => {
    if (!autoFocus || !focus?.airingId) return;
    window.requestAnimationFrame(() => cells.current.get(focus.airingId ?? "")?.focus({ preventScroll: true }));
    // eslint-disable-next-line react-hooks/exhaustive-deps -- once, on showing
  }, []);

  const onKeyDown = (event: React.KeyboardEvent) => {
    const move = KEYS[event.key];
    if (!move || !focus) return;
    event.preventDefault();
    const next = moveFocus(rows, focus, move, geometry.start);
    if (next !== focus) {
      onFocus(next);
      // The cell may need drawing first; focus follows on the next frame.
      window.requestAnimationFrame(() => {
        if (next.airingId) cells.current.get(next.airingId)?.focus({ preventScroll: true });
      });
    }
  };

  const ticks = halfHours(Math.max(drawFrom, geometry.start), Math.min(drawTo, geometry.end));
  const nowX = xOf(geometry, now);

  return (
    <div
      ref={scroller}
      className="relative min-h-0 flex-1 overflow-auto overscroll-contain rounded-[var(--radius-card)] border border-border bg-surface"
      onScroll={() => {
        if (frame.current !== undefined) return;
        frame.current = window.requestAnimationFrame(() => {
          frame.current = undefined;
          measure();
        });
      }}
      onKeyDown={onKeyDown}
      role="grid"
      aria-label="Guide"
      aria-rowcount={rows.length}
    >
      <div className="relative" style={{ width: channelWidth + timelineWidth, height: headerHeight + rows.length * rowHeight }}>
        {/* The time header, stuck to the top. */}
        <div className="sticky top-0 z-20 flex border-b border-border bg-surface-raised" style={{ height: headerHeight }} role="row">
          <div className="sticky left-0 z-30 shrink-0 border-r border-border bg-surface-raised" style={{ width: channelWidth }} />
          <div className="relative flex-1">
            {ticks.map((tick) => (
              <span
                key={tick}
                className="absolute top-0 flex h-full items-center border-l border-border pl-2 text-xs tabular-nums text-muted"
                style={{ left: xOf(geometry, tick) }}
              >
                {clockTime(new Date(tick).toISOString(), timeZone)}
              </span>
            ))}
            {nowX >= 0 && nowX <= timelineWidth ? (
              <span className="absolute bottom-0 h-2 w-2 -translate-x-1/2 rotate-45 bg-negative" style={{ left: nowX }} aria-hidden />
            ) : null}
          </div>
        </div>

        {rows.slice(firstRow, lastRow + 1).map((row, offset) => {
          const index = firstRow + offset;
          return (
            <Row
              key={row.station.id}
              row={row}
              index={index}
              top={headerHeight + index * rowHeight}
              geometry={geometry}
              sizes={sizes}
              drawFrom={drawFrom}
              drawTo={drawTo}
              visibleFrom={Math.max(floorTo(visibleFrom, EDGE_STEP), geometry.start)}
              now={now}
              timeZone={timeZone}
              focusedId={focus?.row === index ? (focus.airingId ?? null) : null}
              menus={menus}
              hasFocus={focus !== null}
              cells={cells}
              onFocus={onFocus}
              onChoose={onChoose}
              onFavorite={onFavorite}
              onHide={onHide}
              onEdit={onEdit}
            />
          );
        })}

        {nowX >= 0 && nowX <= timelineWidth ? (
          <div
            className="pointer-events-none absolute z-10 w-0.5 bg-negative"
            style={{ left: channelWidth + nowX, top: headerHeight, height: rows.length * rowHeight }}
            aria-hidden
          />
        ) : null}
      </div>
    </div>
  );
}

const Row = memo(function Row({
  row,
  index,
  top,
  geometry,
  sizes,
  drawFrom,
  drawTo,
  visibleFrom,
  now,
  timeZone,
  focusedId,
  menus,
  hasFocus,
  cells,
  onFocus,
  onChoose,
  onFavorite,
  onHide,
  onEdit,
}: {
  row: GuideRow;
  index: number;
  top: number;
  geometry: Geometry;
  sizes: GridSizes;
  drawFrom: number;
  drawTo: number;
  visibleFrom: number;
  now: number;
  timeZone: string;
  focusedId: string | null;
  menus: boolean;
  hasFocus: boolean;
  cells: RefObject<Map<string, HTMLDivElement>>;
  onFocus: (focus: Focus) => void;
  onChoose: (station: GuideStation, airing: Airing) => void;
  onFavorite: (station: GuideStation) => void;
  onHide: (station: GuideStation) => void;
  onEdit?: (station: GuideStation) => void;
}) {
  const { station } = row;
  const { channelWidth, rowHeight } = sizes;
  const drawn = row.airings.filter((airing) => Date.parse(airing.ends_at) > drawFrom && Date.parse(airing.starts_at) < drawTo);
  // Without a focus yet, the first row's program on now takes the tab stop.
  const tabStop = focusedId ?? (!hasFocus && index === 0 ? (row.airings.find((airing) => Date.parse(airing.ends_at) > now)?.id ?? null) : null);

  return (
    <div className="absolute left-0 flex w-full border-b border-border" style={{ top, height: rowHeight }} role="row" aria-rowindex={index + 1}>
      <div
        className="sticky left-0 z-10 flex shrink-0 items-center gap-1 border-r border-border bg-surface pr-2"
        style={{ width: channelWidth }}
        role="rowheader"
      >
        {/* The channel itself: what it has on now takes the focus (and the preview). */}
        <button
          type="button"
          aria-label={`Channel ${station.number} ${station.name}: what's on now`}
          aria-pressed={focusedId !== null}
          className={cn("h-full min-w-0 flex-1 px-2 text-left transition-colors", focusedId !== null ? "bg-primary/10" : "hover:bg-border/40")}
          onClick={() => onFocus({ row: index, airingId: airingAt(row.airings, now)?.id ?? null, cursor: now })}
        >
          <span className="flex items-center gap-1 font-mono text-base font-semibold tabular-nums">
            {station.number}
            {station.favorite ? <Star className="h-3 w-3 fill-current text-warning" aria-label="Favourite" /> : null}
          </span>
          <span className="block truncate text-xs text-muted">{station.call_sign ?? station.name}</span>
        </button>
        {menus ? <div className="shrink-0">
          <ActionMenu label={`More for channel ${station.number}`}>
            {(close) => (
              <>
                <ActionMenuItem
                  icon={<Star className="h-4 w-4" aria-hidden />}
                  onSelect={() => {
                    close();
                    onFavorite(station);
                  }}
                >
                  {station.favorite ? "Remove from favourites" : "Add to favourites"}
                </ActionMenuItem>
                <ActionMenuItem
                  icon={<EyeOff className="h-4 w-4" aria-hidden />}
                  onSelect={() => {
                    close();
                    onHide(station);
                  }}
                >
                  Hide from my guide
                </ActionMenuItem>
                {onEdit ? (
                  <ActionMenuItem
                    icon={<Pencil className="h-4 w-4" aria-hidden />}
                    onSelect={() => {
                      close();
                      onEdit(station);
                    }}
                  >
                    Edit channel
                  </ActionMenuItem>
                ) : null}
              </>
            )}
          </ActionMenu>
        </div> : null}
      </div>
      <div className="relative flex-1">
        {drawn.map((airing) => {
          const starts = Date.parse(airing.starts_at);
          const ends = Date.parse(airing.ends_at);
          const left = xOf(geometry, Math.max(starts, geometry.start));
          const width = xOf(geometry, ends) - left;
          const onNow = starts <= now && ends > now;
          const over = ends <= now;
          const cut = starts < visibleFrom;
          const focused = airing.id === focusedId;
          return (
            // A div rather than a button: sticky titles don't stick inside a button.
            <div
              key={airing.id}
              ref={(element) => {
                if (element) cells.current.set(airing.id, element);
                else cells.current.delete(airing.id);
              }}
              role="gridcell"
              tabIndex={airing.id === tabStop ? 0 : -1}
              // The TV layout's arrows find the grid through its tab stop.
              data-tv={airing.id === tabStop ? "" : undefined}
              aria-selected={focused}
              aria-label={`${station.number} ${station.name}: ${airing.title}${airing.subtitle ? `, ${airing.subtitle}` : ""}, ${clockTime(airing.starts_at, timeZone)} to ${clockTime(airing.ends_at, timeZone)}${onNow ? ", on now" : ""}`}
              className={cn(
                "absolute inset-y-0.5 cursor-pointer rounded-[var(--radius-control)] border px-2 text-left transition-colors [clip-path:inset(0_round_var(--radius-control))]",
                onNow ? "border-primary/40 bg-primary/10" : "border-border bg-surface-raised",
                over && "opacity-50",
                focused ? "z-[5] border-primary bg-primary/20 opacity-100" : "hover:bg-border/40",
              )}
              style={{ left: left + 1, width: Math.max(width - 2, 2) }}
              onFocus={() => {
                if (!focused) onFocus({ row: index, airingId: airing.id, cursor: Math.max(starts, Math.min(now, ends - 1), geometry.start) });
              }}
              onClick={() => onChoose(station, airing)}
              onKeyDown={(event) => {
                if (event.key !== "Enter" && event.key !== " ") return;
                event.preventDefault();
                onChoose(station, airing);
              }}
            >
              <span className="sticky flex h-full w-fit min-w-0 max-w-full flex-col justify-center" style={{ left: channelWidth + 8 }}>
                <span className="flex min-w-0 items-center gap-1 truncate text-sm font-medium">
                  {cut ? <ChevronLeft className="h-3.5 w-3.5 shrink-0 text-muted" aria-hidden /> : null}
                  <span className="truncate">{airing.title}</span>
                  {airing.reminded ? <Bell className="h-3 w-3 shrink-0 text-primary" aria-label="Reminder set" /> : null}
                </span>
                {airing.subtitle && width > 90 ? <span className="truncate text-xs text-muted">{airing.subtitle}</span> : null}
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
});
