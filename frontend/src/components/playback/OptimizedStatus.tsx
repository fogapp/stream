import { formatBytes } from "@/lib/bytes";
import { OPTIMIZED_REASON_LABELS, OPTIMIZED_STATE_LABELS, OPTIMIZED_STATE_TONES } from "@/lib/optimized";
import { relativeTime } from "@/lib/time";
import { useOptimizeActions } from "@/hooks/useOptimizeActions";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { ProgressBar } from "@/components/ui/ProgressBar";
import type { OptimizedVersion, OptimizeAction } from "@/types";
import { plural } from "@/lib/format";

/**
 * Where a file's optimized version stands (PROPOSAL §5.5), and the admin's
 * levers: ask for one tonight or now, put it next in line, retry, make it
 * again, say not to make one, delete.
 */
export function OptimizedStatus({ mediaFileId, version, admin }: { mediaFileId: string; version: OptimizedVersion | null; admin: boolean }) {
  const { act } = useOptimizeActions();
  const run = (action: OptimizeAction, now = false) => act.mutate({ action, ids: [mediaFileId], now });
  const busy = act.isPending;
  const state = version?.state ?? null;

  return (
    <div className="space-y-2 text-sm">
      {version ? (
        <div className="flex flex-wrap items-center gap-2">
          <Badge tone={OPTIMIZED_STATE_TONES[version.state]}>{OPTIMIZED_STATE_LABELS[version.state]}</Badge>
          <span className="text-muted">{describe(version)}</span>
        </div>
      ) : (
        <p className="text-muted">None. An optimized version is an H.264 copy every browser plays as-is, made in quiet hours.</p>
      )}
      {version?.state === "encoding" ? <ProgressBar value={version.progress} label="Encoding progress" className="max-w-xs" /> : null}
      {version?.interruption && version.state !== "ready" ? (
        <p className="text-xs text-muted">
          Stopped {version.interruptions === 1 ? "once" : `${version.interruptions} times`} part way, last because {version.interruption}
          {version.interrupted_at ? ` (${relativeTime(version.interrupted_at)})` : ""}.
        </p>
      ) : null}
      {version?.error ? <p className="text-negative">{version.error}</p> : null}
      {admin ? (
        <div className="flex flex-wrap gap-2">
          {state === null || state === "skipped" ? (
            <>
              <Button size="sm" variant="secondary" onClick={() => run("optimize")} disabled={busy}>
                Optimize tonight
              </Button>
              <Button size="sm" variant="secondary" onClick={() => run("optimize", true)} disabled={busy}>
                Optimize now
              </Button>
            </>
          ) : null}
          {state === "failed" ? (
            <>
              <Button size="sm" variant="secondary" onClick={() => run("retry")} disabled={busy}>
                Retry tonight
              </Button>
              <Button size="sm" variant="secondary" onClick={() => run("retry", true)} disabled={busy}>
                Retry now
              </Button>
            </>
          ) : null}
          {state === "queued" ? (
            <Button size="sm" variant="secondary" onClick={() => run("prioritize")} disabled={busy}>
              Do next
            </Button>
          ) : null}
          {state === "queued" && version && !version.run_now ? (
            <Button size="sm" variant="secondary" onClick={() => run("optimize", true)} disabled={busy}>
              Start now
            </Button>
          ) : null}
          {state === "ready" ? (
            <Button size="sm" variant="secondary" onClick={() => run("reencode")} disabled={busy}>
              Make again
            </Button>
          ) : null}
          {state !== "skipped" ? (
            <ConfirmButton size="sm" variant="ghost" onConfirm={() => run("skip")} disabled={busy} question="Never make one?">
              {state === "encoding" ? "Stop, and don't optimize" : "Don't optimize"}
            </ConfirmButton>
          ) : (
            <Button size="sm" variant="ghost" onClick={() => run("unskip")} disabled={busy}>
              Allow again
            </Button>
          )}
          {state !== null && state !== "skipped" ? (
            <ConfirmButton size="sm" variant="ghost" onConfirm={() => run("delete")} disabled={busy} question="Delete it? It may be made again.">
              {state === "encoding" ? "Stop and delete" : "Delete"}
            </ConfirmButton>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

function describe(version: OptimizedVersion): string {
  switch (version.state) {
    case "queued":
      return [
        version.run_now ? "Starts as soon as nothing is being converted for a viewer." : "Encodes in quiet hours.",
        version.reason ? `${OPTIMIZED_REASON_LABELS[version.reason]}.` : null,
        version.prioritized_at ? "Next in line." : null,
      ]
        .filter(Boolean)
        .join(" ");
    case "encoding":
      return `${Math.round(version.progress * 100)}% on ${version.worker ?? "the transcoder"}${version.encoder === "software" ? " (CPU)" : ""}`;
    case "ready":
      return [
        version.height ? `H.264 ${version.height}p` : "H.264",
        version.tonemapped ? "tone-mapped to SDR" : null,
        formatBytes(version.size),
        version.finished_at ? `made ${relativeTime(version.finished_at)}` : null,
      ]
        .filter(Boolean)
        .join(" · ");
    case "failed":
      return `Gave up after ${plural(version.attempts, "attempt")}.`;
    case "skipped":
      return "You said not to make one, so it's never queued on its own.";
  }
}
