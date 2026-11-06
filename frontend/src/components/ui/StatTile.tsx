import type { ReactNode } from "react";
import { Link } from "react-router-dom";
import { cn } from "@/lib/cn";

/**
 * One headline number: a small label, the value, and a line under it saying
 * what the number is doing (a delta against a named period, a caveat, the
 * part of it that needs attention). The KPI row on the Dashboard is a row of
 * these; the value is the only large type on the tile.
 *
 * `tone` colors the hint line, never the value — a status color on a number
 * makes every number look like an alarm.
 */
const HINT_TONES = {
  neutral: "text-muted",
  positive: "text-positive",
  warning: "text-warning",
  danger: "text-negative",
} as const;

export type StatTone = keyof typeof HINT_TONES;

export function StatTile({
  label,
  value,
  hint,
  tone = "neutral",
  icon,
  to,
  className,
}: {
  label: string;
  value: ReactNode;
  hint?: ReactNode;
  tone?: StatTone;
  icon?: ReactNode;
  /** Where the number's detail lives; the whole tile becomes the link. */
  to?: string;
  className?: string;
}) {
  const body = (
    <>
      <div className="flex items-center justify-between gap-2">
        <p className="text-xs uppercase tracking-wide text-muted">{label}</p>
        {icon ? <span className="text-muted" aria-hidden>{icon}</span> : null}
      </div>
      <p className="mt-1 text-2xl font-semibold text-foreground">{value}</p>
      {hint ? <p className={cn("mt-1 text-xs", HINT_TONES[tone])}>{hint}</p> : null}
    </>
  );
  const shell = cn(
    "block rounded-[var(--radius-card)] border border-border bg-surface px-5 py-4",
    to && "transition-colors hover:border-primary/40 hover:bg-surface-raised",
    className,
  );
  return to ? (
    <Link to={to} className={shell}>
      {body}
    </Link>
  ) : (
    <div className={shell}>{body}</div>
  );
}
