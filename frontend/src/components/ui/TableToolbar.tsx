import { useEffect, useState, type ReactNode } from "react";
import { Search } from "lucide-react";
import { useDebouncedValue } from "@/hooks/useDebouncedValue";
import { Button } from "./Button";
import { Input } from "./Input";

/**
 * What sits over a server-side table: a search box (debounced, so a query
 * goes out once typing pauses), the table's filters, how many rows match,
 * and a way back to everything. Filters arrive as children so each table
 * brings its own controls.
 */
export function TableToolbar({
  search,
  onSearch,
  searchLabel = "Search",
  children,
  active,
  onClear,
  summary,
}: {
  search: string;
  onSearch: (value: string) => void;
  searchLabel?: string;
  children?: ReactNode;
  /** Filters set; the clear button shows when any are. */
  active: number;
  onClear: () => void;
  /** "1,204 sessions", say. */
  summary?: ReactNode;
}) {
  const [text, setText] = useState(search);
  const debounced = useDebouncedValue(text, 300);

  // Follow the URL when it changes underneath (a health card, Back).
  useEffect(() => setText(search), [search]);
  useEffect(() => {
    if (debounced.trim() !== search) onSearch(debounced.trim());
    // onSearch is a fresh closure each render; the debounced text is what moves.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [debounced]);

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-3">
        <div className="w-full sm:w-72">
          <Input
            type="search"
            aria-label={searchLabel}
            placeholder={`${searchLabel}…`}
            icon={<Search className="h-4 w-4" />}
            value={text}
            onChange={(event) => setText(event.target.value)}
          />
        </div>
        {children}
      </div>
      {summary || active > 0 ? (
        <div className="flex flex-wrap items-center gap-3 text-sm text-muted">
          {summary ? <span className="tabular-nums">{summary}</span> : null}
          {active > 0 ? (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => {
                setText("");
                onClear();
              }}
            >
              Clear filters ({active})
            </Button>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
