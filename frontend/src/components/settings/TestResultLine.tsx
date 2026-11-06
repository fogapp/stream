import { CheckCircle2, XCircle } from "lucide-react";
import { cn } from "@/lib/cn";
import { relativeTime } from "@/lib/time";
import type { TestConnection } from "@/hooks/useTestConnection";
import type { Testable } from "@/types";
import { Badge } from "@/components/ui/Badge";

/** The one-line outcome of a Test or Check button, or the last recorded test. */
export function TestResultLine({
  ok,
  message,
  at,
  compact = false,
}: {
  ok: boolean | null;
  message: string | null;
  at?: string | null;
  /** The smaller size, for a line under a single field. */
  compact?: boolean;
}) {
  if (ok === null || !message) return null;
  const icon = cn("mt-0.5 shrink-0", compact ? "h-3.5 w-3.5" : "h-4 w-4");
  return (
    <p className={cn("flex items-start gap-1.5", compact ? "text-xs" : "text-sm", ok ? "text-positive" : "text-negative")}>
      {ok ? <CheckCircle2 className={icon} aria-hidden /> : <XCircle className={icon} aria-hidden />}
      <span>
        {message}
        {at ? <span className="text-muted"> · {relativeTime(at)}</span> : null}
      </span>
    </p>
  );
}

/** A connection's Test result: the one just run, else the last one saved. */
export function ConnectionTestLine({ test, stored }: { test: TestConnection; stored: Testable }) {
  return (
    <TestResultLine
      ok={test.result?.ok ?? stored.last_test_ok}
      message={test.result?.message ?? stored.last_test_message}
      at={test.result ? null : stored.last_tested_at}
    />
  );
}

/**
 * Where a connection stands, beside its name: not set up, or set up — and
 * for one that can be paused, on or paused. `label` is what set up is
 * called ("Connected", "Set up").
 */
export function ConnectionBadge({ setUp, enabled, label = "Set up" }: { setUp: boolean; enabled?: boolean; label?: string }) {
  if (!setUp) return <Badge>Not set up</Badge>;
  if (enabled === undefined) return <Badge tone="success">{label}</Badge>;
  return enabled ? <Badge tone="success">On</Badge> : <Badge>Paused</Badge>;
}
