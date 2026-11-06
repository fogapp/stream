import { useRef, type PointerEvent as ReactPointerEvent } from "react";
import { cn } from "@/lib/cn";
import { LAYER_LABELS, LAYER_TONES, minutesToTime, WEEKDAYS } from "@/lib/live";
import { segmentsOf } from "@/lib/stationClock";
import type { StationBlock } from "@/types";

const HOUR_PX = 18;
const STEP = 15;

const RANK = { base: 0, daypart: 1, appointment: 2, special: 3 } as const;

/**
 * A channel's week at a glance (PROPOSAL §7.7): the base mix underneath,
 * and each daypart, appointment and special as a band on its days. A band
 * is chosen by clicking; dragged, it moves; its lower edge stretches it —
 * a quarter hour at a time. With the keyboard, arrows move a chosen band
 * and Shift+arrows stretch it. Double-clicking an empty hour adds a
 * daypart there.
 */
export function WeekClock({
  blocks,
  selected,
  onSelect,
  onChange,
  onAdd,
  weekStart,
}: {
  blocks: StationBlock[];
  selected: number | null;
  onSelect: (index: number) => void;
  onChange: (index: number, block: StationBlock) => void;
  onAdd: (day: number, minute: number) => void;
  weekStart: Date;
}) {
  const drag = useRef<{
    index: number;
    mode: "move" | "stretch";
    y: number;
    block: StationBlock;
  } | null>(null);
  const segments = blocks
    .flatMap((block, index) => segmentsOf(block, index, weekStart))
    // Drawn in the order they give way, so what wins is on top: within a kind, the first listed.
    .sort(
      (a, b) =>
        RANK[blocks[a.index]?.layer ?? "base"] -
          RANK[blocks[b.index]?.layer ?? "base"] || b.index - a.index,
    );

  const shift = (
    block: StationBlock,
    minutes: number,
    mode: "move" | "stretch",
  ): StationBlock => {
    const start = block.start_minute ?? 0;
    const end = block.end_minute ?? 60;
    if (mode === "stretch") {
      const length = ((end - start + 1440) % 1440 || 1440) + minutes;
      return {
        ...block,
        end_minute:
          (start + Math.min(Math.max(length, STEP), 1440 - STEP)) % 1440 ||
          1440,
      };
    }
    const wrap = (value: number) => ((value % 1440) + 1440) % 1440;
    return {
      ...block,
      start_minute: wrap(start + minutes),
      end_minute: wrap(end + minutes) || 1440,
    };
  };

  const onPointerDown = (
    event: ReactPointerEvent,
    index: number,
    mode: "move" | "stretch",
  ) => {
    const block = blocks[index];
    if (!block) return;
    event.stopPropagation();
    onSelect(index);
    (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
    drag.current = { index, mode, y: event.clientY, block };
  };
  const onPointerMove = (event: ReactPointerEvent) => {
    const current = drag.current;
    if (!current) return;
    const minutes =
      Math.round(((event.clientY - current.y) / HOUR_PX) * (60 / STEP)) * STEP;
    onChange(current.index, shift(current.block, minutes, current.mode));
  };
  const onPointerUp = () => {
    drag.current = null;
  };

  return (
    <div
      className="overflow-x-auto rounded-[var(--radius-card)] border border-border bg-surface"
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
    >
      <div className="grid min-w-[26rem] grid-cols-[2.5rem_repeat(7,minmax(0,1fr))]">
        <div />
        {WEEKDAYS.map((day) => (
          <div
            key={day}
            className="border-b border-l border-border py-1 text-center text-xs font-medium text-muted"
          >
            {day}
          </div>
        ))}
        <div className="relative" style={{ height: HOUR_PX * 24 }}>
          {[0, 3, 6, 9, 12, 15, 18, 21].map((hour) => (
            <span
              key={hour}
              className="absolute right-1 -translate-y-1/2 text-[10px] tabular-nums text-muted"
              style={{ top: hour * HOUR_PX }}
            >
              {hour === 0 ? "" : minutesToTime(hour * 60)}
            </span>
          ))}
        </div>
        {WEEKDAYS.map((dayName, day) => (
          <div
            key={dayName}
            className="relative border-l border-border bg-surface-raised/40"
            style={{ height: HOUR_PX * 24 }}
            onDoubleClick={(event) => {
              const box = event.currentTarget.getBoundingClientRect();
              const minute =
                Math.floor(((event.clientY - box.top) / HOUR_PX) * 4) * 15;
              onAdd(day, Math.min(Math.max(minute, 0), 1380));
            }}
          >
            {Array.from({ length: 23 }, (_, hour) => (
              <div
                key={hour}
                className="absolute inset-x-0 border-t border-border/50"
                style={{ top: (hour + 1) * HOUR_PX }}
                aria-hidden
              />
            ))}
            {segments
              .filter((segment) => segment.day === day)
              .map((segment) => {
                const block = blocks[segment.index];
                if (!block) return null;
                const chosen = selected === segment.index;
                const label =
                  block.name ?? block.label ?? LAYER_LABELS[block.layer];
                return (
                  <button
                    key={`${segment.index}-${segment.continued ? "c" : "s"}`}
                    type="button"
                    aria-label={`${label}, ${WEEKDAYS[day]} ${minutesToTime(block.start_minute)}–${minutesToTime(block.end_minute)}`}
                    aria-pressed={chosen}
                    className={cn(
                      "absolute inset-x-0.5 cursor-grab touch-none overflow-hidden rounded-[var(--radius-control)] border px-1 text-left text-[11px] leading-tight",
                      LAYER_TONES[block.layer],
                      chosen && "z-10 ring-2 ring-primary",
                    )}
                    style={{
                      top: (segment.start / 60) * HOUR_PX,
                      height: Math.max(
                        ((segment.end - segment.start) / 60) * HOUR_PX,
                        6,
                      ),
                    }}
                    onPointerDown={(event) =>
                      onPointerDown(event, segment.index, "move")
                    }
                    onClick={() => onSelect(segment.index)}
                    onKeyDown={(event) => {
                      const step =
                        event.key === "ArrowUp"
                          ? -STEP
                          : event.key === "ArrowDown"
                            ? STEP
                            : 0;
                      if (!step) return;
                      event.preventDefault();
                      onChange(
                        segment.index,
                        shift(block, step, event.shiftKey ? "stretch" : "move"),
                      );
                    }}
                  >
                    {segment.continued ? null : (
                      <span className="block truncate font-medium">
                        {label}
                      </span>
                    )}
                    <span
                      className="absolute inset-x-0 bottom-0 h-1.5 cursor-ns-resize"
                      onPointerDown={(event) =>
                        onPointerDown(event, segment.index, "stretch")
                      }
                      aria-hidden
                    />
                  </button>
                );
              })}
          </div>
        ))}
      </div>
    </div>
  );
}
