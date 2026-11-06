import { Loader2, Move, Play, X } from "lucide-react";
import { useMiniFrame } from "@/components/player/miniFrame";
import { IconButton } from "@/components/ui/IconButton";
import { cn } from "@/lib/cn";
import { formatClock } from "@/lib/format";
import type { LastWatched } from "@/lib/lastWatched";

/**
 * What was playing before the page was reloaded, waiting in the
 * mini-player's corner on the frame it was left on. Resuming starts it
 * there as the mini-player (the server knows where to pick up); closing
 * forgets it.
 */
export function ResumeCard({
  item,
  starting,
  onResume,
  onDismiss,
}: {
  item: LastWatched;
  starting: boolean;
  onResume: () => void;
  onDismiss: () => void;
}) {
  const mini = useMiniFrame();
  const progress = item.duration > 0 ? Math.min(item.position / item.duration, 1) : 0;

  return (
    <div
      data-theme="dark"
      role="region"
      aria-label={`Resume ${item.title}`}
      className={cn(
        "group fixed z-50 touch-none select-none overflow-hidden rounded-[var(--radius-card)] bg-background text-foreground shadow-xl ring-1 ring-border",
        mini.dragging && "cursor-grabbing",
      )}
      style={{ left: mini.box.left, top: mini.box.top, width: mini.box.width, height: mini.box.height }}
      {...mini.frameProps}
    >
      {item.still ? <img src={item.still} alt="" className="absolute inset-0 h-full w-full object-contain" draggable={false} /> : null}
      <div className="absolute inset-0 flex flex-col justify-between bg-gradient-to-t from-background via-background/40 to-background/60">
        <div className="flex gap-1 p-2">
          <IconButton label="Move or resize" data-drag-handle className="cursor-grab" onKeyDown={mini.onKeyDown}>
            <Move className="h-4 w-4" aria-hidden />
          </IconButton>
          <span className="flex-1" />
          <IconButton label="Dismiss" onClick={onDismiss}>
            <X className="h-4 w-4" aria-hidden />
          </IconButton>
        </div>
        <button
          type="button"
          onClick={onResume}
          disabled={starting}
          aria-label={`Resume ${item.title}`}
          className="absolute left-1/2 top-1/2 flex h-11 w-11 -translate-x-1/2 -translate-y-1/2 items-center justify-center rounded-full bg-primary text-primary-foreground shadow-lg transition-colors hover:bg-primary-hover disabled:opacity-70"
        >
          {starting ? <Loader2 className="h-5 w-5 animate-spin" aria-hidden /> : <Play className="h-5 w-5 fill-current" aria-hidden />}
        </button>
        <div className="min-w-0 px-3 pb-2">
          <p className="truncate text-sm font-medium">{item.title}</p>
          <p className="truncate text-xs text-muted">
            {[item.subtitle, item.position > 0 ? `${formatClock(item.position)}${item.duration > 0 ? ` of ${formatClock(item.duration)}` : ""}` : null]
              .filter(Boolean)
              .join(" · ")}
          </p>
        </div>
        <div className="h-0.5 bg-foreground/20">
          <div className="h-full bg-primary" style={{ width: `${progress * 100}%` }} />
        </div>
      </div>
    </div>
  );
}
