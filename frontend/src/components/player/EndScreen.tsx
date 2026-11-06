import { useEffect, useRef, useState } from "react";
import { Check, RotateCcw, X } from "lucide-react";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { ProgressBar } from "@/components/ui/ProgressBar";
import { Button } from "@/components/ui/Button";
import { IconButton } from "@/components/ui/IconButton";
import { Toggle } from "@/components/ui/Toggle";
import { cn } from "@/lib/cn";
import { formatClock } from "@/lib/format";
import type { NextItem, VideoCard } from "@/types";
import { asNext, autoplayPick, type Offers } from "@/components/player/offers";

/**
 * Over a finished video's last frame: one more from the same channel, a few
 * from other channels, and Replay. Choosing one plays it in the same player.
 * With Autoplay on, the first one not yet watched plays after a countdown;
 * after a run of them with nobody touching anything it asks instead.
 */
export function EndScreen({
  offers,
  belowBar,
  autoplay,
  seconds,
  stillWatching,
  onAutoplay,
  onPrefetch,
  onPlay,
  onReplay,
  onClose,
}: {
  offers: Offers;
  /** The title bar is showing at the top: start below it. */
  belowBar: boolean;
  autoplay: boolean;
  /** How long the countdown to the autoplayed one is. */
  seconds: number;
  /** Enough played by themselves in a row: Autoplay waits for someone. */
  stillWatching: boolean;
  onAutoplay: (on: boolean) => void;
  onPrefetch: (next: NextItem) => void;
  onPlay: (next: NextItem, automatic: boolean) => void;
  onReplay: () => void;
  onClose: () => void;
}) {
  const pick = autoplay ? autoplayPick(offers) : null;
  const { next } = offers;
  // The one about to play is always among those shown, whatever the width.
  const others = pick && pick.id !== next?.id ? [pick, ...offers.others.filter((card) => card.id !== pick.id)] : offers.others;
  return (
    <div
      role="region"
      aria-label="Watch next"
      // Under the title bar, which stays usable above it.
      className={cn("@container pointer-events-auto absolute inset-0 flex overflow-y-auto bg-background/80 px-4 pb-4", belowBar ? "pt-20" : "pt-3")}
      onClick={(event) => event.stopPropagation()}
      onDoubleClick={(event) => event.stopPropagation()}
    >
      {/* Centred while it fits; scrolled from the top when it doesn't. */}
      <div className="m-auto w-full max-w-5xl space-y-2 @md:space-y-3">
        <div className="flex items-center gap-2">
          <h2 className="min-w-0 flex-1 truncate text-sm font-semibold uppercase tracking-wide text-muted">
            {pick && stillWatching ? (
              "Still watching?"
            ) : pick ? (
              <Countdown key={pick.id} seconds={seconds} onStart={() => onPrefetch(asNext(pick))} onDone={() => onPlay(asNext(pick), true)} />
            ) : (
              "Watch next"
            )}
          </h2>
          <Toggle label="Autoplay" checked={autoplay} onChange={onAutoplay} />
          <Button size="sm" variant="secondary" onClick={onReplay}>
            <RotateCcw className="h-4 w-4" aria-hidden />
            Replay
          </Button>
          <IconButton label="Close" onClick={onClose}>
            <X className="h-4 w-4" aria-hidden />
          </IconButton>
        </div>
        {/* One row, as many as the player is wide for: the channel's first. */}
        <ul className="grid grid-cols-2 gap-2 @md:gap-3 @xl:grid-cols-3 @4xl:grid-cols-4">
          {next ? (
            <li>
              <Offer
                card={next}
                label={next.channel ? `More from ${next.channel.title}` : "More from this channel"}
                featured={pick ? pick.id === next.id : true}
                onPlay={(chosen) => onPlay(chosen, false)}
              />
            </li>
          ) : null}
          {others.map((card, index) => {
            const shown = index + (next ? 1 : 0);
            return (
              <li key={card.id} className={cn(shown === 2 && "hidden @xl:block", shown >= 3 && "hidden @4xl:block")}>
                <Offer card={card} label={card.channel?.title ?? null} featured={pick?.id === card.id} onPlay={(chosen) => onPlay(chosen, false)} />
              </li>
            );
          })}
        </ul>
      </div>
    </div>
  );
}

function Countdown({ seconds, onStart, onDone }: { seconds: number; onStart: () => void; onDone: () => void }) {
  const [left, setLeft] = useState(seconds);
  // Read when they're needed: the player passes new ones every render.
  const start = useRef(onStart);
  const done = useRef(onDone);
  done.current = onDone;
  useEffect(() => start.current(), []);
  useEffect(() => {
    if (left <= 0) {
      done.current();
      return;
    }
    const timer = window.setTimeout(() => setLeft((value) => value - 1), 1000);
    return () => window.clearTimeout(timer);
  }, [left]);
  return <span role="timer">Up next in {Math.max(left, 0)}</span>;
}

function Offer({ card, label, featured = false, onPlay }: { card: VideoCard; label: string | null; featured?: boolean; onPlay: (next: NextItem) => void }) {
  return (
    <button
      type="button"
      onClick={() => onPlay(asNext(card))}
      className="group block w-full rounded-[var(--radius-card)] p-1 text-left @md:p-1.5 transition-colors hover:bg-surface-raised"
    >
      <div className="relative">
        <ArtworkImage
          image={card.images.thumb ?? null}
          sizes="16rem"
          className={cn("aspect-video rounded-[var(--radius-control)] ring-1 ring-border", featured && "ring-primary")}
          fallback={<span className="px-2 text-center text-xs text-muted">{card.title}</span>}
        />
        {card.duration_seconds ? (
          <span className="absolute bottom-1.5 right-1.5 rounded bg-background/85 px-1 font-mono text-xs tabular-nums text-foreground">
            {formatClock(card.duration_seconds)}
          </span>
        ) : null}
        {card.progress ? <ProgressBar variant="overlay" value={card.progress} className="absolute inset-x-0 bottom-0 overflow-hidden rounded-b-[var(--radius-control)]" /> : null}
      </div>
      {/* In a small player, the picture and a line of title. */}
      <div className="min-w-0 pt-1.5">
        {label ? <p className={cn("hidden truncate text-xs @md:block", featured ? "text-primary" : "text-muted")}>{label}</p> : null}
        <p className="line-clamp-1 text-xs font-medium leading-snug text-foreground group-hover:underline @md:line-clamp-2 @md:text-sm">{card.title}</p>
        {card.watched ? (
          <p className="hidden items-center gap-1 text-xs text-muted @md:flex">
            <Check className="h-3 w-3" aria-hidden />
            Watched
          </p>
        ) : null}
      </div>
    </button>
  );
}
