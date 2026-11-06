import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { librariesQuery } from "@/lib/queries";
import { Checkbox } from "@/components/ui/Checkbox";
import { FormError, FormFooter } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import { Toggle } from "@/components/ui/Toggle";
import type { SmartRules } from "@/types";

export const EMPTY_RULES: SmartRules = {
  kinds: ["movie", "show"],
  library_ids: [],
  genres: [],
  unwatched: false,
  uhd: false,
  hdr: false,
  sort: "added",
  limit: 100,
};

/** A smart collection's rules (PROPOSAL §7.2): worked out whenever it's opened. */
export function SmartRulesForm({
  initialTitle,
  initialRules,
  pending,
  error,
  submitLabel,
  onSubmit,
  onCancel,
}: {
  initialTitle: string;
  initialRules: SmartRules;
  pending: boolean;
  error: string | null;
  submitLabel: string;
  onSubmit: (title: string, rules: SmartRules) => void;
  onCancel: () => void;
}) {
  const libraries = useQuery(librariesQuery());
  const [title, setTitle] = useState(initialTitle);
  const [rules, setRules] = useState<SmartRules>(initialRules);
  const [genres, setGenres] = useState(initialRules.genres.join(", "));
  const set = <K extends keyof SmartRules>(key: K, value: SmartRules[K]) => setRules((current) => ({ ...current, [key]: value }));
  const number = (text: string) => (text.trim() === "" ? null : Number(text));
  const titled = (libraries.data ?? []).filter((library) => library.kind === "movies" || library.kind === "shows");

  return (
    <form
      className="space-y-4 rounded-[var(--radius-card)] border border-border bg-surface p-4"
      onSubmit={(event) => {
        event.preventDefault();
        onSubmit(title, { ...rules, genres: genres.split(",").map((genre) => genre.trim()).filter(Boolean) });
      }}
    >
      <Input label="Name" value={title} onChange={(event) => setTitle(event.target.value)} required />
      <div className="flex flex-wrap gap-6">
        <Checkbox label="Movies" checked={rules.kinds.includes("movie")} onChange={(on) => set("kinds", on ? [...rules.kinds, "movie"] : rules.kinds.filter((kind) => kind !== "movie"))} />
        <Checkbox label="Shows" checked={rules.kinds.includes("show")} onChange={(on) => set("kinds", on ? [...rules.kinds, "show"] : rules.kinds.filter((kind) => kind !== "show"))} />
      </div>
      {titled.length > 1 ? (
        <fieldset className="space-y-2">
          <legend className="text-sm font-medium text-foreground">From (none ticked: all libraries)</legend>
          {titled.map((library) => (
            <Checkbox
              key={library.id}
              label={library.name}
              checked={rules.library_ids.includes(library.id)}
              onChange={(on) => set("library_ids", on ? [...rules.library_ids, library.id] : rules.library_ids.filter((id) => id !== library.id))}
            />
          ))}
        </fieldset>
      ) : null}
      <Input label="Genres" hint="Any of these, separated by commas" value={genres} onChange={(event) => setGenres(event.target.value)} placeholder="Crime, Thriller" />
      <div className="grid gap-4 sm:grid-cols-4">
        <Input label="From year" type="number" value={rules.year_from ?? ""} onChange={(event) => set("year_from", number(event.target.value))} />
        <Input label="To year" type="number" value={rules.year_to ?? ""} onChange={(event) => set("year_to", number(event.target.value))} />
        <Input label="Rated at least" type="number" step="0.1" min={0} max={10} value={rules.min_rating ?? ""} onChange={(event) => set("min_rating", number(event.target.value))} />
        <Input label="Added in the last … days" type="number" min={1} value={rules.added_within_days ?? ""} onChange={(event) => set("added_within_days", number(event.target.value))} />
      </div>
      <div className="flex flex-wrap gap-6">
        <Toggle label="Unwatched (by whoever's looking)" checked={rules.unwatched} onChange={(on) => set("unwatched", on)} />
        <Toggle label="4K" checked={rules.uhd} onChange={(on) => set("uhd", on)} />
        <Toggle label="HDR" checked={rules.hdr} onChange={(on) => set("hdr", on)} />
      </div>
      <div className="grid gap-4 sm:grid-cols-2">
        <Select label="Order" value={rules.sort} onChange={(event) => set("sort", event.target.value as SmartRules["sort"])}>
          <option value="added">Newest added</option>
          <option value="title">Title</option>
          <option value="year">Newest year</option>
          <option value="rating">Highest rated</option>
        </Select>
        <Input label="At most" type="number" min={1} max={200} value={rules.limit} onChange={(event) => set("limit", Number(event.target.value) || 100)} />
      </div>
      <FormError message={error} />
      <FormFooter label={submitLabel} pending={pending} onCancel={onCancel} />
    </form>
  );
}
