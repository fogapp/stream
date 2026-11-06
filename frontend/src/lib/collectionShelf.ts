import type { MissingPart, MovieCard, ShowCard } from "@/types";

export type ShelfEntry = { kind: "item"; item: MovieCard | ShowCard } | { kind: "missing"; part: MissingPart };

/**
 * A TMDB collection's shelf: the titles had, in the server's (release)
 * order, with the ones nobody has placed by year among them — before the
 * first title from a later year, and last when TMDB gives no date.
 */
export function interleave(items: (MovieCard | ShowCard)[], missing: MissingPart[]): ShelfEntry[] {
  const shelf: ShelfEntry[] = items.map((item) => ({ kind: "item", item }));
  const yearOf = (entry: ShelfEntry) => (entry.kind === "missing" ? entry.part.year : entry.item.year);
  for (const part of missing) {
    const year = part.year;
    const at = year === null ? -1 : shelf.findIndex((entry) => (yearOf(entry) ?? Infinity) > year);
    shelf.splice(at === -1 ? shelf.length : at, 0, { kind: "missing", part });
  }
  return shelf;
}
