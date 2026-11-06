import { Trash2 } from "lucide-react";
import { SourceFields } from "@/components/live/SourceFields";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import { cn } from "@/lib/cn";
import { dayMask, LAYER_HINTS, LAYER_LABELS, minutesToTime, ORDERING_HINTS, ORDERING_LABELS, timeToMinutes, WEEKDAYS } from "@/lib/live";
import { STATION_ORDERINGS, type StationBlock, type StationLayer, type StationOptions, type StationOrdering } from "@/types";

const TIMED: StationLayer[] = ["daypart", "appointment", "special"];

/** One block of a channel's programming (PROPOSAL §7.7): when it's in charge, what it draws from, and in what order. */
export function BlockEditor({
  block,
  options,
  onChange,
  onRemove,
}: {
  block: StationBlock;
  options: StationOptions;
  onChange: (block: StationBlock) => void;
  onRemove: () => void;
}) {
  const set = <K extends keyof StationBlock>(key: K, value: StationBlock[K]) => onChange({ ...block, [key]: value });
  const timed = block.layer !== "base";
  const inOrder = block.ordering !== "shuffle";

  return (
    <div className="space-y-4">
      <div className="flex items-start gap-3">
        <div className="min-w-0 flex-1">
          <h3 className="font-semibold">{block.name || block.label || LAYER_LABELS[block.layer]}</h3>
          <p className="text-sm text-muted">{LAYER_HINTS[block.layer]}</p>
        </div>
        {timed ? (
          <Button variant="ghost" size="sm" onClick={onRemove}>
            <Trash2 className="h-4 w-4" aria-hidden />
            Remove
          </Button>
        ) : null}
      </div>

      {timed ? (
        <>
          <div className="grid gap-4 sm:grid-cols-2">
            <Input label="Name" value={block.name ?? ""} placeholder="Primetime" onChange={(event) => set("name", event.target.value || null)} />
            <Select label="Kind" value={block.layer} onChange={(event) => set("layer", event.target.value as StationLayer)}>
              {TIMED.map((layer) => (
                <option key={layer} value={layer}>
                  {LAYER_LABELS[layer]}
                </option>
              ))}
            </Select>
          </div>
          <fieldset>
            <legend className="mb-1.5 text-sm font-medium">Days</legend>
            <div className="flex flex-wrap gap-1">
              {WEEKDAYS.map((day, index) => (
                <button
                  key={day}
                  type="button"
                  aria-pressed={dayMask(block.days, index)}
                  className={cn(
                    "h-8 w-11 rounded-[var(--radius-control)] border text-sm",
                    dayMask(block.days, index) ? "border-primary bg-primary text-primary-foreground" : "border-border bg-surface-raised text-muted",
                  )}
                  onClick={() => {
                    const days = block.days ^ (1 << index);
                    if (days !== 0) set("days", days);
                  }}
                >
                  {day}
                </button>
              ))}
            </div>
          </fieldset>
          <div className="grid gap-4 sm:grid-cols-2">
            <Input
              label="Starts"
              type="time"
              step={300}
              value={minutesToTime(block.start_minute)}
              onChange={(event) => set("start_minute", timeToMinutes(event.target.value))}
            />
            <Input
              label="Ends"
              type="time"
              step={300}
              value={minutesToTime(block.end_minute)}
              hint="Earlier than the start runs past midnight."
              onChange={(event) => set("end_minute", timeToMinutes(event.target.value) || 1440)}
            />
          </div>
          {block.layer === "special" ? (
            <div className="grid gap-4 sm:grid-cols-2">
              <Input label="From" type="date" value={block.starts_on ?? ""} onChange={(event) => set("starts_on", event.target.value || null)} required />
              <Input label="Until" type="date" value={block.ends_on ?? ""} onChange={(event) => set("ends_on", event.target.value || null)} required />
            </div>
          ) : null}
        </>
      ) : null}

      <div className="grid gap-4 sm:grid-cols-2">
        <Select label="Order" value={block.ordering} onChange={(event) => set("ordering", event.target.value as StationOrdering)} hint={ORDERING_HINTS[block.ordering]}>
          {STATION_ORDERINGS.map((ordering) => (
            <option key={ordering} value={ordering}>
              {ORDERING_LABELS[ordering]}
            </option>
          ))}
        </Select>
        {block.ordering === "marathon" ? (
          <Input
            label="Episodes in a row"
            type="number"
            min={1}
            max={50}
            value={block.marathon_length}
            onChange={(event) => set("marathon_length", Math.min(Math.max(Number(event.target.value) || 1, 1), 50))}
          />
        ) : inOrder ? (
          <Select label="When a show runs out" value={block.loops ? "loop" : "yield"} onChange={(event) => set("loops", event.target.value === "loop")}>
            <option value="loop">Start it over</option>
            <option value="yield">Give the slot to what's underneath</option>
          </Select>
        ) : null}
      </div>
      <SourceFields value={block.source} onChange={(source) => set("source", source)} options={options} />
    </div>
  );
}
