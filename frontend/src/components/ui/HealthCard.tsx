import { Link } from "react-router-dom";
import { AlertOctagon, AlertTriangle, CheckCircle2 } from "lucide-react";
import { cn } from "@/lib/cn";

/** A check's verdict: fine, worth a look, or something to do. */
const TONES = {
  positive: { icon: CheckCircle2, text: "text-positive", edge: "border-l-positive" },
  warning: { icon: AlertTriangle, text: "text-warning", edge: "border-l-warning" },
  danger: { icon: AlertOctagon, text: "text-negative", edge: "border-l-negative" },
} as const;

export type HealthTone = keyof typeof TONES;

/**
 * One health check: what it watches, its verdict in words and color, the
 * number behind it, a sentence, and — when there's something to do — what,
 * as a link to where it's done. The whole card is the link, so the number
 * is one press from the rows that make it.
 */
export function HealthCard({
  title,
  verdict,
  tone,
  metric,
  detail,
  action,
  to,
}: {
  title: string;
  verdict: string;
  tone: HealthTone;
  metric: string;
  detail: string;
  action?: string | null;
  to: string;
}) {
  const { icon: Icon, text, edge } = TONES[tone];
  return (
    <Link
      to={to}
      className={cn(
        "flex flex-col gap-2 rounded-[var(--radius-card)] border border-l-4 border-border bg-surface px-4 py-3",
        "transition-colors hover:bg-surface-raised",
        edge,
      )}
    >
      <div className="flex items-center justify-between gap-2">
        <p className="text-xs font-medium uppercase tracking-wide text-muted">{title}</p>
        <span className={cn("inline-flex items-center gap-1 text-xs font-medium", text)}>
          <Icon className="h-3.5 w-3.5" aria-hidden />
          {verdict}
        </span>
      </div>
      <p className="text-2xl font-semibold tabular-nums text-foreground">{metric}</p>
      <p className="text-sm text-muted">{detail}</p>
      {action ? <p className={cn("text-sm font-medium", text)}>{action} →</p> : null}
    </Link>
  );
}
