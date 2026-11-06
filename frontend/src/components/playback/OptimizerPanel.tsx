import { Link } from "react-router-dom";
import { Pause, Play, Search } from "lucide-react";
import { formatBytes } from "@/lib/bytes";
import { ENCODER_LABELS } from "@/lib/encoders";
import { OPTIMIZER_STATE_LABELS, OPTIMIZER_STATE_TONES, formatDuration, formatHour } from "@/lib/optimized";
import { relativeTime, untilTime } from "@/lib/time";
import { useOptimizeActions } from "@/hooks/useOptimizeActions";
import { useOptimizerStatus } from "@/hooks/useOptimizerStatus";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { ErrorState, LoadingState } from "@/components/ui/PageState";
import { ProgressBar } from "@/components/ui/ProgressBar";
import type { EncoderKind } from "@/types";

/**
 * What the optimizer is doing, or why it isn't, and the levers that change
 * it: pause, look for files now, the running encodes as they go, and the
 * space they're taking.
 */
export function OptimizerPanel() {
  const status = useOptimizerStatus();
  const { scan, pause } = useOptimizeActions();

  if (status.isPending) return <LoadingState label="Asking the optimizer…" />;
  if (status.isError) return <ErrorState message="Could not ask the optimizer what it's doing." onRetry={() => void status.refetch()} />;
  const data = status.data;
  const { budget, quiet_hours: quiet, queue } = data;

  return (
    <section aria-label="Optimizer" className="space-y-4 rounded-[var(--radius-card)] border border-border bg-surface px-4 py-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0 space-y-1">
          <div className="flex flex-wrap items-center gap-2">
            <Badge tone={OPTIMIZER_STATE_TONES[data.state]}>{OPTIMIZER_STATE_LABELS[data.state]}</Badge>
            <p className="text-sm text-foreground">{data.message}</p>
          </div>
          <p className="text-xs text-muted">
            Quiet hours {formatHour(quiet.start_hour)} to {formatHour(quiet.end_hour)}
            {quiet.now ? " (now)" : quiet.next_start_at ? `, next ${untilTime(quiet.next_start_at)}` : ""}.{" "}
            {data.transcoder.online
              ? `Transcoder running${data.transcoder.encoder ? `, encoding with ${ENCODER_LABELS[data.transcoder.encoder as EncoderKind] ?? data.transcoder.encoder}` : ""}.`
              : "No transcoder has been heard from."}
            {data.transcoder.remote_nodes.length > 0
              ? ` Remote: ${data.transcoder.remote_nodes.map((node) => node.name).join(", ")}.`
              : ""}
            {!data.automatic ? " Files aren't queued automatically (Settings › General)." : ""}
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button
            size="sm"
            variant="secondary"
            onClick={() => pause.mutate(!data.paused)}
            disabled={pause.isPending}
          >
            {data.paused ? <Play className="h-4 w-4" aria-hidden /> : <Pause className="h-4 w-4" aria-hidden />}
            {data.paused ? "Resume optimizing" : "Pause optimizing"}
          </Button>
          <Button
            size="sm"
            variant="secondary"
            onClick={() => scan.mutate()}
            disabled={scan.isPending || !data.automatic}
            title={data.automatic ? undefined : "Optimizing automatically is off in Settings › General"}
          >
            <Search className="h-4 w-4" aria-hidden />
            Find files to optimize now
          </Button>
        </div>
      </div>

      {data.encoding.length > 0 ? (
        <ul className="space-y-3">
          {data.encoding.map((version) => (
            <li key={version.id} className="space-y-1.5">
              <div className="flex flex-wrap items-baseline justify-between gap-2 text-sm">
                <Link to={`/files/${version.media_file_id}`} className="min-w-0 truncate font-medium text-foreground hover:underline">
                  {version.title ?? version.filename ?? "Unknown file"}
                </Link>
                <span className="tabular-nums text-muted">
                  {[
                    `${Math.round(version.progress * 100)}%`,
                    version.speed ? `${version.speed}× real time` : null,
                    version.eta_seconds !== null ? `about ${formatDuration(version.eta_seconds)} left` : null,
                    version.worker ? `on ${version.worker}${version.encoder === "software" ? " (CPU)" : ""}` : null,
                  ]
                    .filter(Boolean)
                    .join(" · ")}
                </span>
              </div>
              <ProgressBar value={version.progress} label={`Encoding ${version.title ?? version.filename ?? "file"}`} />
            </li>
          ))}
        </ul>
      ) : null}

      <div className="space-y-1.5">
        <div className="flex flex-wrap items-baseline justify-between gap-2 text-sm">
          <span className="text-foreground">
            Space: {formatBytes(budget.used_bytes)} of {formatBytes(budget.budget_bytes)}
            {queue.estimated_bytes > 0 ? <span className="text-muted"> · about {formatBytes(queue.estimated_bytes)} more queued</span> : null}
          </span>
          <span className="flex flex-wrap gap-3 text-xs">
            <Link to="/playback?tab=optimized&states=ready&unplayed_days=90&sort=size&dir=desc" className="text-primary hover:underline">
              Free up space
            </Link>
            <Link to="/settings" className="text-primary hover:underline">
              Change in Settings
            </Link>
          </span>
        </div>
        <ProgressBar value={budget.budget_bytes ? budget.used_bytes / budget.budget_bytes : 0} label="Space used by optimized versions" />
        <p className="text-xs text-muted">
          {queue.queued} waiting{queue.run_now ? ` (${queue.run_now} now)` : ""}
          {queue.interrupted ? ` · ${queue.interrupted} stopped part way` : ""}
          {queue.failed ? ` · ${queue.failed} failed` : ""}
          {queue.skipped ? ` · ${queue.skipped} not optimizing` : ""}
          {data.transcoder.last_seen_at ? ` · transcoder heard from ${relativeTime(data.transcoder.last_seen_at)}` : ""}
        </p>
      </div>
    </section>
  );
}
