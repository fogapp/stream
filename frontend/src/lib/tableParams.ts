import type { SortDirection, SortState } from "@/lib/dataTable";

/**
 * A server-side table's state, as the API takes it: filters, sort and page.
 * Arrays go out Rails-style (`methods[]=remux&methods[]=direct`); empty
 * values are left off entirely, so an unset filter never reaches the server
 * as an empty string.
 */
export type ApiQuery = Record<string, string | number | boolean | readonly string[] | null | undefined>;

export function toSearch(query: ApiQuery): string {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(query)) {
    if (value === null || value === undefined || value === "" || value === false) continue;
    if (Array.isArray(value)) value.forEach((each) => params.append(`${key}[]`, each));
    else params.set(key, String(value));
  }
  const search = params.toString();
  return search ? `?${search}` : "";
}

/** A sort from the URL, or the table's default when it says nothing usable. */
export function readSort(params: URLSearchParams, fallback: SortState): SortState {
  const key = params.get("sort");
  const direction = params.get("dir");
  if (!key) return fallback;
  return { key, direction: direction === "asc" || direction === "desc" ? (direction as SortDirection) : fallback.direction };
}
