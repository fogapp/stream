import { cn } from "@/lib/cn";

export interface KeyValue {
  key: string;
  value: string;
}

/**
 * Small `key: value` chips — the numbers behind a sentence. An activity
 * row's payload, an item's ingest metrics, a feature row's scores: anywhere
 * a handful of labelled scalars want to sit on one line without becoming a
 * table.
 */
export function KeyValueChips({
  entries,
  className,
}: {
  entries: readonly KeyValue[];
  className?: string;
}) {
  if (entries.length === 0) return null;
  return (
    <p className={cn("flex flex-wrap gap-1.5", className)}>
      {entries.map((entry) => (
        <span
          key={entry.key}
          className="rounded-[var(--radius-control)] border border-border bg-surface-raised px-1.5 py-0.5 font-mono text-[11px] text-muted"
        >
          {entry.key}: <span className="text-foreground">{entry.value}</span>
        </span>
      ))}
    </p>
  );
}
