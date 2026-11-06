import { useNavigate } from "react-router-dom";
import { Play, RotateCcw } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { formatClock } from "@/lib/format";
import type { PlayableKind } from "@/types";
import { PlayOnScreen } from "@/components/remote/PlayOnScreen";
import { PipButton } from "@/components/pip/PipButton";

/** Play / Resume, and Start over beside it when there's a resume point. */
export function PlayButtons({
  kind,
  id,
  resumeAt,
  label,
}: {
  kind: PlayableKind;
  id: string;
  resumeAt: number | null;
  /** Overrides "Play", e.g. "Play S01E03". */
  label?: string;
}) {
  const navigate = useNavigate();
  const resuming = resumeAt !== null && resumeAt > 0;
  return (
    <div className="flex flex-wrap items-center gap-2">
      <Button size="lg" data-watch={`/watch/${kind}/${id}`} onClick={() => navigate(`/watch/${kind}/${id}`)}>
        <Play className="h-5 w-5 fill-current" aria-hidden />
        {resuming ? `Resume from ${formatClock(resumeAt)}` : (label ?? "Play")}
      </Button>
      {resuming ? (
        <Button size="lg" variant="secondary" data-watch={`/watch/${kind}/${id}?from=start`} onClick={() => navigate(`/watch/${kind}/${id}?from=start`)}>
          <RotateCcw className="h-4 w-4" aria-hidden />
          Start over
        </Button>
      ) : null}
      <PipButton source={{ kind: "title", playable: kind, id, title: label ?? "" }} />
      <PlayOnScreen kind={kind} id={id} />
    </div>
  );
}
