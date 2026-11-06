import { useEffect, useState } from "react";
import { Play } from "lucide-react";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { Button } from "@/components/ui/Button";
import type { PlaybackSessionInfo } from "@/types";

/**
 * Up next (PROPOSAL §7.3): when the credits start, the next episode with a
 * countdown to it, and a way out. After three episodes in a row with nobody
 * touching anything, it asks instead of counting (binge mode).
 */
export function UpNext({
  next,
  seconds,
  stillWatching,
  onPlay,
  onDismiss,
}: {
  next: NonNullable<PlaybackSessionInfo["next_up"]>;
  seconds: number;
  stillWatching: boolean;
  onPlay: () => void;
  onDismiss: () => void;
}) {
  const [left, setLeft] = useState(seconds);
  useEffect(() => {
    if (stillWatching) return;
    if (left <= 0) {
      onPlay();
      return;
    }
    const timer = window.setTimeout(() => setLeft((value) => value - 1), 1000);
    return () => window.clearTimeout(timer);
  }, [left, stillWatching, onPlay]);

  return (
    <div className="pointer-events-auto absolute bottom-24 right-4 w-80 max-w-[calc(100%-2rem)] overflow-hidden rounded-[var(--radius-card)] bg-surface shadow-xl ring-1 ring-border sm:right-6">
      <ArtworkImage image={next.image} sizes="20rem" className="aspect-video" fallback={<span className="text-sm text-muted">{next.code ?? next.title}</span>} />
      <div className="space-y-3 p-3">
        <div>
          <p className="text-xs uppercase tracking-wide text-muted">{stillWatching ? "Still watching?" : `Up next in ${left}`}</p>
          <p className="truncate font-medium text-foreground">{[next.code, next.title].filter(Boolean).join(" · ")}</p>
          {next.playlist_id && next.show_title ? <p className="truncate text-xs text-muted">{next.show_title}</p> : null}
        </div>
        <div className="flex gap-2">
          <Button size="sm" onClick={onPlay}>
            <Play className="h-4 w-4 fill-current" aria-hidden />
            {stillWatching ? "Keep watching" : "Play now"}
          </Button>
          <Button size="sm" variant="ghost" onClick={onDismiss}>
            {stillWatching ? "I'm done" : "Watch credits"}
          </Button>
        </div>
      </div>
    </div>
  );
}
