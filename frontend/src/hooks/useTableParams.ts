import { useCallback, useMemo } from "react";
import { useSearchParams } from "react-router-dom";
import type { SortState } from "@/lib/dataTable";
import { readSort, type ApiQuery } from "@/lib/tableParams";

export interface TableParams {
  sort: SortState;
  /** From 1, as the API counts. */
  page: number;
  get: (key: string) => string | null;
  getAll: (key: string) => string[];
  /** Changes filters and goes back to the first page; null or [] removes one. */
  set: (changes: Record<string, string | readonly string[] | null>) => void;
  setSort: (sort: SortState) => void;
  setPage: (page: number) => void;
  /** Removes every filter (the sort and anything outside the table stay). */
  clear: () => void;
  /** How many filters are set, for "Clear filters (3)". */
  active: number;
  /** Filters, sort and page as the API takes them. */
  query: ApiQuery;
}

/**
 * A server-side table's filters, sort and page, kept in the URL: a link can
 * open the table already filtered (the Playback page's health cards do), the
 * back button undoes a filter, and a reload keeps the view. `filters` names
 * the keys that belong to this table; everything else in the URL (the tab)
 * is left alone.
 */
export function useTableParams({
  filters,
  arrays = [],
  defaultSort,
}: {
  filters: readonly string[];
  /** The filters that hold several values (`?methods=a&methods=b`). */
  arrays?: readonly string[];
  defaultSort: SortState;
}): TableParams {
  const [params, setParams] = useSearchParams();

  const update = useCallback(
    (change: (next: URLSearchParams) => void) => {
      setParams(
        (current) => {
          const next = new URLSearchParams(current);
          change(next);
          return next;
        },
        { replace: true },
      );
    },
    [setParams],
  );

  return useMemo(() => {
    const sort = readSort(params, defaultSort);
    const page = Math.max(1, Number(params.get("page")) || 1);
    const query: ApiQuery = { sort: sort.key, direction: sort.direction, page };
    let active = 0;
    for (const key of filters) {
      if (arrays.includes(key)) {
        const values = params.getAll(key);
        if (values.length > 0) {
          query[key] = values;
          active += 1;
        }
      } else {
        const value = params.get(key);
        if (value) {
          query[key] = value;
          active += 1;
        }
      }
    }

    return {
      sort,
      page,
      get: (key) => params.get(key),
      getAll: (key) => params.getAll(key),
      set: (changes) =>
        update((next) => {
          for (const [key, value] of Object.entries(changes)) {
            next.delete(key);
            if (Array.isArray(value)) value.forEach((each) => next.append(key, each));
            else if (typeof value === "string" && value !== "") next.set(key, value);
          }
          next.delete("page");
        }),
      setSort: (next) =>
        update((search) => {
          search.set("sort", next.key);
          search.set("dir", next.direction);
          search.delete("page");
        }),
      setPage: (next) =>
        update((search) => {
          if (next <= 1) search.delete("page");
          else search.set("page", String(next));
        }),
      clear: () =>
        update((search) => {
          filters.forEach((key) => search.delete(key));
          search.delete("page");
        }),
      active,
      query,
    };
  }, [params, filters, arrays, defaultSort, update]);
}
