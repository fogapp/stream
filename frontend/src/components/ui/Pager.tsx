import { ChevronLeft, ChevronRight } from "lucide-react";
import { IconButton } from "./IconButton";

/**
 * "101–200 of 812" with previous/next — for a list paged in the browser.
 * `page` counts from 0. Renders nothing when everything fits on one page.
 */
export function Pager({
  page,
  per,
  total,
  onChange,
  noun = "rows",
}: {
  page: number;
  per: number;
  total: number;
  onChange: (page: number) => void;
  noun?: string;
}) {
  const pages = Math.max(1, Math.ceil(total / per));
  if (pages === 1) return null;
  const first = page * per + 1;
  const last = Math.min(total, (page + 1) * per);

  return (
    <nav aria-label="Pages" className="flex items-center justify-end gap-2 text-sm text-muted">
      <span className="tabular-nums">
        {first.toLocaleString()}–{last.toLocaleString()} of {total.toLocaleString()} {noun}
      </span>
      <IconButton label="Previous page" disabled={page === 0} onClick={() => onChange(page - 1)}>
        <ChevronLeft className="h-4 w-4" aria-hidden />
      </IconButton>
      <IconButton label="Next page" disabled={page >= pages - 1} onClick={() => onChange(page + 1)}>
        <ChevronRight className="h-4 w-4" aria-hidden />
      </IconButton>
    </nav>
  );
}
