import {
  useRef,
  type KeyboardEvent,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";
import { GripVertical } from "lucide-react";
import { IconButton } from "@/components/ui/IconButton";
import { cn } from "@/lib/cn";
import { LAYER_TONES, minutesToTime, WEEKDAYS } from "@/lib/live";
import type { StationBlock, StationLayer } from "@/types";

/** Top to bottom, the order the scheduler gives way in. */
const GROUPS: { layer: StationLayer; title: string }[] = [
  { layer: "special", title: "Specials" },
  { layer: "appointment", title: "Appointments" },
  { layer: "daypart", title: "Dayparts" },
  { layer: "base", title: "Mix" },
];

/** When a block airs, in a few words. */
function when(block: StationBlock): string | null {
  if (block.layer === "base") return "Whenever nothing else is on";
  const hours = `${minutesToTime(block.start_minute)}–${minutesToTime(block.end_minute)}`;
  if (block.layer === "special")
    return block.starts_on === block.ends_on
      ? block.starts_on
      : `${block.starts_on ?? "?"} – ${block.ends_on ?? "?"}`;
  const days = WEEKDAYS.filter((_, day) => block.days & (1 << day));
  const daysText =
    days.length === 7
      ? "Daily"
      : days.length === 5 && !(block.days & 0b1100000)
        ? "Weekdays"
        : days.join(" ");
  return `${daysText} · ${hours}`;
}

/**
 * A channel's layers as the scheduler weighs them (PROPOSAL §7.7): specials
 * over appointments over dayparts over the mix, and within a kind, the one
 * higher in the list wins where two overlap. A layer is reordered within
 * its kind by dragging its handle, or with the arrow keys on the handle.
 * Each kind's add control sits in its heading.
 */
export function LayerList({
  blocks,
  selected,
  onSelect,
  onMove,
  addControls,
  addForms = {},
}: {
  blocks: StationBlock[];
  selected: number;
  onSelect: (index: number) => void;
  /** Move the block at `from` to `to`, both indexes into `blocks`. */
  onMove: (from: number, to: number) => void;
  addControls: Partial<Record<StationLayer, ReactNode>>;
  /** A kind's open add form, shown under its heading. */
  addForms?: Partial<Record<StationLayer, ReactNode>>;
}) {
  const dragging = useRef<{ index: number; layer: StationLayer } | null>(null);
  const list = useRef<HTMLDivElement>(null);

  const onPointerDown = (
    event: ReactPointerEvent,
    index: number,
    layer: StationLayer,
  ) => {
    event.preventDefault();
    (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
    dragging.current = { index, layer };
    onSelect(index);
  };
  const onPointerMove = (event: ReactPointerEvent) => {
    const current = dragging.current;
    if (!current) return;
    const over = document
      .elementFromPoint(event.clientX, event.clientY)
      ?.closest<HTMLElement>("[data-layer-index]");
    if (!over || over.dataset.layer !== current.layer) return;
    const target = Number(over.dataset.layerIndex);
    if (target === current.index) return;
    onMove(current.index, target);
    dragging.current = { ...current, index: target };
  };
  const onPointerUp = () => {
    dragging.current = null;
  };
  const onKeyDown = (
    event: KeyboardEvent,
    index: number,
    siblings: number[],
  ) => {
    const at = siblings.indexOf(index);
    const target =
      event.key === "ArrowUp"
        ? siblings[at - 1]
        : event.key === "ArrowDown"
          ? siblings[at + 1]
          : undefined;
    if (target === undefined) return;
    event.preventDefault();
    onMove(index, target);
    // Rows are keyed by place, so the handle that moved is the one now at `target`.
    requestAnimationFrame(() =>
      list.current
        ?.querySelector<HTMLElement>(`[data-layer-index="${target}"] button`)
        ?.focus(),
    );
  };

  return (
    <div
      ref={list}
      className="space-y-4"
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerCancel={onPointerUp}
    >
      {GROUPS.map(({ layer, title }) => {
        const members = blocks.flatMap((block, index) =>
          block.layer === layer ? [index] : [],
        );
        return (
          <div key={layer} className="space-y-1">
            <div className="flex items-center justify-between gap-2">
              <h3 className="text-xs font-medium uppercase tracking-wide text-muted">
                {title}
              </h3>
              {addControls[layer]}
            </div>
            {addForms[layer]}
            {members.length === 0 && !addForms[layer] ? (
              <p className="text-sm text-muted">None</p>
            ) : null}
            <ul className="space-y-1" aria-label={title}>
              {members.map((index) => {
                const block = blocks[index] as StationBlock;
                const movable = layer !== "base" && members.length > 1;
                return (
                  <li
                    key={index}
                    data-layer-index={index}
                    data-layer={layer}
                    className={cn(
                      "flex items-stretch overflow-hidden rounded-[var(--radius-control)] border",
                      LAYER_TONES[layer],
                      index === selected && "ring-2 ring-primary",
                    )}
                  >
                    {movable ? (
                      <IconButton
                        label={`Reorder ${block.name || title}: drag, or the up and down arrows`}
                        size="sm"
                        className="shrink-0 cursor-grab touch-none rounded-none hover:bg-transparent active:cursor-grabbing"
                        onPointerDown={(event) =>
                          onPointerDown(event, index, layer)
                        }
                        onKeyDown={(event) => onKeyDown(event, index, members)}
                      >
                        <GripVertical className="h-4 w-4" aria-hidden />
                      </IconButton>
                    ) : (
                      <span className="w-2 shrink-0" aria-hidden />
                    )}
                    <button
                      type="button"
                      className="min-w-0 flex-1 py-1.5 pr-2 text-left"
                      aria-current={index === selected}
                      onClick={() => onSelect(index)}
                    >
                      <span className="block truncate text-sm font-medium">
                        {block.name ||
                          block.label ||
                          (layer === "base"
                            ? "The channel's mix"
                            : title.slice(0, -1))}
                      </span>
                      <span className="block truncate text-xs text-muted">
                        {when(block)}
                      </span>
                    </button>
                  </li>
                );
              })}
            </ul>
          </div>
        );
      })}
    </div>
  );
}
