import { describe, expect, it } from "vitest";
import { interleave } from "./collectionShelf";
import type { MissingPart, MovieCard } from "@/types";

const movie = (title: string, year: number | null): MovieCard => ({
  kind: "movie", id: title, title, year, content_rating: null, runtime_minutes: null, images: {}, progress: null, watched: false,
  tmdb_id: null, imdb_id: null,
});
const part = (title: string, year: number | null): MissingPart => ({ tmdb_id: title.length, title, year, release_date: null, overview: null, images: {} });
const titles = (list: ReturnType<typeof interleave>) => list.map((entry) => (entry.kind === "missing" ? `(${entry.part.title})` : entry.item.title));

describe("interleave", () => {
  it("places what's missing by year among what's had, and undated ones last", () => {
    expect(titles(interleave([movie("Alien", 1979), movie("Prometheus", 2012)], [part("Aliens", 1986), part("Alien³", 1992), part("Next", null)]))).toEqual([
      "Alien",
      "(Aliens)",
      "(Alien³)",
      "Prometheus",
      "(Next)",
    ]);
  });

  it("is the series alone when nothing is had, and the titles alone when nothing is missing", () => {
    expect(titles(interleave([], [part("Aliens", 1986), part("Alien³", 1992)]))).toEqual(["(Aliens)", "(Alien³)"]);
    expect(titles(interleave([movie("Alien", 1979)], []))).toEqual(["Alien"]);
  });
});
