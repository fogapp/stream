import { useEffect, useRef } from "react";
import { Button } from "@/components/ui/Button";
import type { MarkerKind, PlaybackMarker } from "@/types";

const LABELS: Record<MarkerKind, string> = { intro: "Skip intro", recap: "Skip recap", credits: "Skip credits" };

/**
 * "Skip intro" while the playhead is inside a marker (PROPOSAL §7.3), and
 * the skip itself when the profile always skips this kind for this show —
 * once per marker, so seeking back into an intro lets you watch it.
 */
export function SkipButton({
  markers,
  current,
  autoSkip,
  canAlwaysSkip,
  onSkip,
  onAlwaysSkip,
}: {
  markers: PlaybackMarker[];
  current: number;
  autoSkip: Record<MarkerKind, boolean>;
  canAlwaysSkip: boolean;
  onSkip: (to: number) => void;
  onAlwaysSkip: (kind: MarkerKind) => void;
}) {
  const skipped = useRef(new Set<string>());
  // Credits are Up next's business on an episode; the button still offers
  // them on a film.
  const active = markers.find((marker) => current >= marker.start && current < marker.end - 1);

  useEffect(() => {
    if (!active || !autoSkip[active.kind]) return;
    const key = `${active.kind}:${active.start}`;
    if (skipped.current.has(key)) return;
    skipped.current.add(key);
    onSkip(active.end);
  }, [active, autoSkip, onSkip]);

  if (!active || autoSkip[active.kind]) return null;
  return (
    <div className="pointer-events-auto absolute bottom-24 right-4 flex items-center gap-2 sm:right-6">
      {canAlwaysSkip ? (
        <Button variant="ghost" size="sm" onClick={() => onAlwaysSkip(active.kind)}>
          Always skip
        </Button>
      ) : null}
      <Button variant="secondary" size="lg" onClick={() => onSkip(active.end)}>
        {LABELS[active.kind]}
      </Button>
    </div>
  );
}
