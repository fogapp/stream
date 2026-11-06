import { Badge } from "@/components/ui/Badge";
import { cn } from "@/lib/cn";
import { clockTime, LAYER_TONES } from "@/lib/live";
import type { StationBlock, StationPreview } from "@/types";

const DAY = 86_400_000;
const TONES = { info: "info", warning: "warning", danger: "danger" } as const;

/**
 * The next seven days as saving would schedule them (PROPOSAL §7.7): a
 * strip per day, each program coloured by the block that chose it, and
 * what's worth knowing above it.
 */
export function WeekPreview({
  preview,
  blocks,
  timeZone,
  dayStart,
  pending,
}: {
  preview: StationPreview | undefined;
  blocks: StationBlock[];
  timeZone: string;
  /** Midnight today on the household's clock. */
  dayStart: number;
  pending: boolean;
}) {
  return (
    <div className={cn("space-y-3 transition-opacity", pending && "opacity-60")} aria-busy={pending}>
      {preview?.warnings.length ? (
        <ul className="space-y-1.5">
          {preview.warnings.map((warning) => (
            <li key={warning.text} className="flex items-start gap-2 text-sm">
              <Badge tone={TONES[warning.tone]}>{warning.tone === "danger" ? "Problem" : warning.tone === "warning" ? "Note" : "Info"}</Badge>
              <span>{warning.text}</span>
            </li>
          ))}
        </ul>
      ) : null}
      <div className="space-y-1">
        {Array.from({ length: 7 }, (_, offset) => {
          const from = dayStart + offset * DAY;
          const airings = (preview?.airings ?? []).filter((airing) => Date.parse(airing.ends_at) > from && Date.parse(airing.starts_at) < from + DAY);
          return (
            <div key={offset} className="flex items-center gap-2">
              <span className="w-12 shrink-0 text-xs text-muted">
                {new Intl.DateTimeFormat(undefined, { weekday: "short", timeZone }).format(new Date(from + DAY / 2))}
              </span>
              <div className="relative h-7 flex-1 overflow-hidden rounded-[var(--radius-control)] bg-background" data-testid="preview-day">
                {airings.map((airing) => {
                  const left = Math.max((Date.parse(airing.starts_at) - from) / DAY, 0);
                  const right = Math.min((Date.parse(airing.ends_at) - from) / DAY, 1);
                  const block = airing.block_index !== null ? blocks[airing.block_index] : null;
                  return (
                    <div
                      key={airing.id}
                      title={`${clockTime(airing.starts_at, timeZone)} ${airing.title}${airing.subtitle ? ` · ${airing.subtitle}` : ""}`}
                      className={cn(
                        "absolute inset-y-0 truncate border-r border-background px-0.5 text-[10px] leading-7",
                        airing.filler ? "bg-border/40" : block ? LAYER_TONES[block.layer] : LAYER_TONES.base,
                      )}
                      style={{ left: `${left * 100}%`, width: `${(right - left) * 100}%` }}
                    >
                      {right - left > 0.04 ? airing.title : ""}
                    </div>
                  );
                })}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
