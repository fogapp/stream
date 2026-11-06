import type { ReactNode } from "react";

/** Horizontal page padding, shared by every page section so they line up. */
const PAGE_X = "px-4 sm:px-6 lg:px-8";

export function PageHeader({
  title,
  description,
  actions,
}: {
  title: string;
  description?: string;
  actions?: ReactNode;
}) {
  return (
    <header className={`flex flex-col gap-3 border-b border-border py-4 sm:flex-row sm:items-start sm:justify-between sm:gap-4 lg:py-6 ${PAGE_X}`}>
      <div className="min-w-0">
        <h1 className="text-lg font-semibold text-foreground">{title}</h1>
        {description ? <p className="mt-1 text-sm text-muted">{description}</p> : null}
      </div>
      {actions ? <div className="flex shrink-0 flex-wrap items-center gap-2">{actions}</div> : null}
    </header>
  );
}
