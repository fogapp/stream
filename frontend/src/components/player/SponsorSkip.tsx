import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/Button";
import { SPONSOR_CATEGORY_LABELS } from "@/lib/libraries";
import type { SponsorSegmentInfo } from "@/types";

/**
 * SponsorBlock in the player (PROPOSAL §5.4): a segment set to skip is
 * skipped once, with a moment to take it back; one set to ask offers a
 * button; one set to show is only on the timeline.
 */
export function SponsorSkip({ segments, current, onSeek }: { segments: SponsorSegmentInfo[]; current: number; onSeek: (to: number) => void }) {
  const done = useRef(new Set<string>());
  const [skipped, setSkipped] = useState<SponsorSegmentInfo | null>(null);
  const active = segments.find((segment) => segment.action !== "show" && current >= segment.start && current < segment.end - 0.5);

  useEffect(() => {
    if (!active || active.action !== "skip") return;
    const key = `${active.category}:${active.start}`;
    if (done.current.has(key)) return;
    done.current.add(key);
    onSeek(active.end);
    setSkipped(active);
  }, [active, onSeek]);

  useEffect(() => {
    if (!skipped) return;
    const timer = window.setTimeout(() => setSkipped(null), 5000);
    return () => window.clearTimeout(timer);
  }, [skipped]);

  if (skipped) {
    return (
      <div className="pointer-events-auto absolute bottom-24 left-4 flex items-center gap-3 rounded-[var(--radius-card)] bg-surface/95 px-3 py-2 text-sm shadow-lg sm:left-6">
        <span className="text-foreground">Skipped {SPONSOR_CATEGORY_LABELS[skipped.category].label.toLowerCase()}</span>
        <Button
          variant="ghost"
          size="sm"
          onClick={() => {
            onSeek(skipped.start);
            setSkipped(null);
          }}
        >
          Undo
        </Button>
      </div>
    );
  }
  if (!active || active.action !== "ask") return null;
  return (
    <div className="pointer-events-auto absolute bottom-24 left-4 sm:left-6">
      <Button variant="secondary" size="lg" onClick={() => onSeek(active.end)}>
        Skip {SPONSOR_CATEGORY_LABELS[active.category].label.toLowerCase()}
      </Button>
    </div>
  );
}
