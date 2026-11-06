import { Checkbox } from "@/components/ui/Checkbox";
import { ChipPicker, type ChipOption } from "@/components/ui/ChipPicker";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import { Toggle } from "@/components/ui/Toggle";
import { RATING_CEILINGS } from "@/lib/ratings";
import type { StationOptions, StationSource, StationSourceKind } from "@/types";

const counted = (list: { value: string; count: number }[]): ChipOption[] =>
  list.map((entry) => ({ value: entry.value, label: entry.value, hint: String(entry.count) }));

/**
 * What one block of a channel draws from (PROPOSAL §7.7): picked titles
 * (and YouTube channels) narrow it to themselves, everything else narrows
 * further. Networks pick shows and studios pick films.
 */
export function SourceFields({ value, onChange, options }: { value: StationSource; onChange: (value: StationSource) => void; options: StationOptions }) {
  const set = <K extends keyof StationSource>(key: K, next: StationSource[K]) => onChange({ ...value, [key]: next });
  const kinds = value.kinds ?? ["movie", "episode"];
  const toggleKind = (kind: StationSourceKind, on: boolean) => {
    const next = on ? [...kinds, kind] : kinds.filter((existing) => existing !== kind);
    if (next.length === 0) return;
    // Picked channels narrow everything else to what's picked: they go with the videos.
    onChange({ ...value, kinds: next, ...(kind === "video" && !on ? { channel_ids: [] } : {}) });
  };
  const number = (text: string) => (text.trim() === "" ? null : Number(text));
  const shows: ChipOption[] = options.shows.map((show) => ({ value: show.id, label: show.title, hint: show.year ? String(show.year) : undefined }));
  const collections: ChipOption[] = options.collections.map((collection) => ({ value: collection.id, label: collection.title }));
  const channels: ChipOption[] = options.youtube_channels.map((channel) => ({ value: channel.id, label: channel.title }));
  const profiles: ChipOption[] = options.profiles.map((profile) => ({ value: profile.id, label: profile.name }));
  const genres = counted(options.genres);
  const keywords = counted(options.keywords);

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-6">
        <Checkbox label="Episodes" checked={kinds.includes("episode")} onChange={(on) => toggleKind("episode", on)} />
        <Checkbox label="Films" checked={kinds.includes("movie")} onChange={(on) => toggleKind("movie", on)} />
        <Checkbox label="YouTube videos" checked={kinds.includes("video")} onChange={(on) => toggleKind("video", on)} />
      </div>
      {kinds.includes("video") ? (
        <ChipPicker
          label="Only these YouTube channels"
          hint="None chosen: every channel's videos. Videos have no genres, keywords, networks, studios, ratings or people, so any of those leaves them out."
          options={channels}
          selected={value.channel_ids ?? []}
          onChange={(ids) => set("channel_ids", ids)}
        />
      ) : null}
      <div className="grid gap-4 md:grid-cols-2">
        <ChipPicker label="Only these shows" hint="None chosen: every show that fits the rules." options={shows} selected={value.show_ids ?? []} onChange={(ids) => set("show_ids", ids)} />
        <ChipPicker label="Only these collections" options={collections} selected={value.collection_ids ?? []} onChange={(ids) => set("collection_ids", ids)} />
        <ChipPicker label="Networks" hint="Shows that aired on any of these." options={counted(options.networks)} selected={value.networks ?? []} onChange={(list) => set("networks", list)} />
        <ChipPicker label="Studios" hint="Films from any of these." options={counted(options.studios)} selected={value.studios ?? []} onChange={(list) => set("studios", list)} />
        <ChipPicker label="Genres" hint="Any of these." options={genres} selected={value.genres ?? []} onChange={(list) => set("genres", list)} />
        <ChipPicker label="Not these genres" options={genres} selected={value.exclude_genres ?? []} onChange={(list) => set("exclude_genres", list)} />
        <ChipPicker label="Keywords" hint="TMDB's, like christmas or heist." options={keywords} selected={value.keywords ?? []} onChange={(list) => set("keywords", list)} allowCustom />
        <ChipPicker label="Not these keywords" options={keywords} selected={value.exclude_keywords ?? []} onChange={(list) => set("exclude_keywords", list)} allowCustom />
        <ChipPicker label="Never these shows" options={shows} selected={value.exclude_show_ids ?? []} onChange={(ids) => set("exclude_show_ids", ids)} />
      </div>
      <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
        <Input label="From year" type="number" value={value.year_from ?? ""} onChange={(event) => set("year_from", number(event.target.value))} />
        <Input label="To year" type="number" value={value.year_to ?? ""} onChange={(event) => set("year_to", number(event.target.value))} />
        <Input label="Shortest (minutes)" type="number" min={1} value={value.min_minutes ?? ""} onChange={(event) => set("min_minutes", number(event.target.value))} />
        <Input label="Longest (minutes)" type="number" min={1} value={value.max_minutes ?? ""} onChange={(event) => set("max_minutes", number(event.target.value))} />
      </div>
      <div className="grid gap-4 md:grid-cols-2">
        <Input label="Rated at least" type="number" step="0.1" min={0} max={10} value={value.min_rating ?? ""} onChange={(event) => set("min_rating", number(event.target.value))} />
        <Select label="Suitable for" value={value.max_rating_age?.toString() ?? ""} onChange={(event) => set("max_rating_age", number(event.target.value))}>
          {RATING_CEILINGS.map((choice) => (
            <option key={choice.value} value={choice.value}>
              {choice.label}
            </option>
          ))}
        </Select>
      </div>
      <div className="flex flex-wrap gap-6">
        {value.max_rating_age !== null && value.max_rating_age !== undefined ? (
          <Toggle label="Include unrated titles" checked={value.allow_unrated ?? true} onChange={(on) => set("allow_unrated", on)} />
        ) : null}
        <Toggle label="Include specials (season 0)" checked={value.include_specials ?? false} onChange={(on) => set("include_specials", on)} />
        <Toggle
          label="Only what hasn't been watched"
          checked={value.unwatched ?? false}
          onChange={(on) => onChange({ ...value, unwatched: on, ...(on ? {} : { unwatched_profile_ids: [] }) })}
        />
      </div>
      {value.unwatched ? (
        <ChipPicker
          label="Watched by"
          hint="None chosen: anything any profile has finished is left out. Read each night, so what's already on the schedule stays."
          options={profiles}
          selected={value.unwatched_profile_ids ?? []}
          onChange={(ids) => set("unwatched_profile_ids", ids)}
        />
      ) : null}
    </div>
  );
}
