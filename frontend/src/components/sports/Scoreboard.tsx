import type { ReactNode } from "react";

/** A game that's on, said the same way on every scoreboard. */
export function LiveMark() {
  return (
    <span className="inline-flex shrink-0 items-center gap-1.5 font-semibold uppercase tracking-wide text-negative">
      <span className="h-1.5 w-1.5 animate-pulse rounded-full bg-negative" aria-hidden />
      Live
    </span>
  );
}

/** Games in one state, under a heading: live, coming up, or how the rest ended. */
export function GameGroup({ id, label, children }: { id: string; label: string; children: ReactNode }) {
  return (
    <section className="space-y-3" aria-labelledby={id}>
      <h2 id={id} className="text-sm font-semibold uppercase tracking-wide text-muted">
        {label}
      </h2>
      <div className="grid gap-4 md:grid-cols-2 2xl:grid-cols-3">{children}</div>
    </section>
  );
}
