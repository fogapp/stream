import type { ReactNode } from "react";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { formatClock } from "@/lib/format";
import { clockTime } from "@/lib/live";
import type { Airing, Station } from "@/types";

/**
 * What shows the instant a channel is chosen (PROPOSAL §7.7), before its
 * picture arrives — and between programs, what's next: the number, the
 * name, and the program over its own still.
 */
export function TuningCard({
  station,
  airing,
  next,
  timeZone,
  now,
  message,
  action,
}: {
  station: Station | null;
  airing: Airing | null;
  next: Airing | null;
  timeZone: string;
  now: number;
  /** In place of the program: "Nothing on", an error. */
  message?: string;
  /** What to do about the message: "Try again". */
  action?: ReactNode;
}) {
  const shown = airing ?? null;
  const image = shown ? (shown.images.backdrop ?? shown.images.still ?? shown.images.poster) : null;
  const until = !shown && next ? Math.max((Date.parse(next.starts_at) - now) / 1000, 0) : null;
  return (
    <div className="absolute inset-0 flex items-center justify-center overflow-hidden bg-background" data-testid={shown ? "tuning-card" : "live-slate"}>
      {image ? (
        <div className="absolute inset-0 scale-110 opacity-40 blur-2xl" aria-hidden>
          <ArtworkImage image={image} sizes="100vw" className="h-full w-full object-cover" />
        </div>
      ) : null}
      <div className="relative max-w-lg space-y-2 px-6 text-center">
        <p className="font-mono text-6xl font-semibold tabular-nums">{station?.number}</p>
        <p className="text-sm uppercase tracking-wide text-muted">{station?.name}</p>
        {message ? <p className="pt-6 text-muted">{message}</p> : null}
        {action ? <div className="pt-4">{action}</div> : null}
        {shown ? (
          <div className="pt-6">
            <p className="text-2xl font-semibold">{shown.title}</p>
            {shown.subtitle ? <p className="text-muted">{shown.subtitle}</p> : null}
          </div>
        ) : next && !message ? (
          <div className="space-y-1 pt-6">
            <p className="text-sm text-muted">Up next at {clockTime(next.starts_at, timeZone)}</p>
            <p className="text-2xl font-semibold">{next.title}</p>
            {next.subtitle ? <p className="text-muted">{next.subtitle}</p> : null}
            {until !== null ? <p className="font-mono tabular-nums text-muted">in {formatClock(until)}</p> : null}
          </div>
        ) : null}
      </div>
    </div>
  );
}
