import type { ReactNode } from "react";
import { Button } from "./Button";

/**
 * What to do with the rows ticked in a table: how many, the actions, and a
 * way to untick them all. Renders nothing with nothing ticked, so a table's
 * header doesn't carry controls that can't do anything.
 */
export function BulkActionBar({
  count,
  noun = "selected",
  onClear,
  children,
}: {
  count: number;
  noun?: string;
  onClear: () => void;
  children: ReactNode;
}) {
  if (count === 0) return null;
  return (
    <div
      role="region"
      aria-label="Selected rows"
      className="flex flex-wrap items-center gap-2 rounded-[var(--radius-card)] border border-primary/30 bg-primary/5 px-3 py-2"
    >
      <span className="text-sm font-medium tabular-nums text-foreground">
        {count.toLocaleString()} {noun}
      </span>
      <div className="flex flex-wrap items-center gap-2">{children}</div>
      <Button variant="ghost" size="sm" className="ml-auto" onClick={onClear}>
        Clear selection
      </Button>
    </div>
  );
}
