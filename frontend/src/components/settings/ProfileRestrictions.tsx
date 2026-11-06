import { useQuery } from "@tanstack/react-query";
import { librariesQuery } from "@/lib/queries";
import { Checkbox } from "@/components/ui/Checkbox";
import { ErrorState, LoadingState } from "@/components/ui/PageState";
import { Select } from "@/components/ui/Select";
import { Toggle } from "@/components/ui/Toggle";
import type { ProfileInfo } from "@/types";
import { RATING_CEILINGS } from "@/lib/ratings";

export type Restrictions = Pick<
  ProfileInfo,
  | "kind"
  | "max_rating_age"
  | "allow_unrated"
  | "library_ids"
  | "curated"
  | "up_next_seconds"
  | "always_skip_intro"
  | "always_skip_credits"
  | "still_watching_after"
>;

export const OPEN: Restrictions = {
  kind: "standard",
  max_rating_age: null,
  allow_unrated: false,
  library_ids: [],
  curated: false,
  up_next_seconds: null,
  always_skip_intro: false,
  always_skip_credits: false,
  still_watching_after: null,
};

/** What a profile may see and how it plays (PROPOSAL §7.4): the admin's part of a profile. */
export function ProfileRestrictions({ value, onChange }: { value: Restrictions; onChange: (value: Restrictions) => void }) {
  const libraries = useQuery(librariesQuery());
  const set = <K extends keyof Restrictions>(key: K, next: Restrictions[K]) => onChange({ ...value, [key]: next });
  const number = (text: string) => (text === "" ? null : Number(text));

  return (
    <div className="space-y-5">
      <Toggle
        label="Kid profile"
        hint="No settings, admin pages or activity from this profile."
        checked={value.kind === "kid"}
        onChange={(kid) => set("kind", kid ? "kid" : "standard")}
      />
      <div className="grid gap-4 sm:grid-cols-2">
        <Select label="Rated for up to" value={value.max_rating_age?.toString() ?? ""} onChange={(event) => set("max_rating_age", number(event.target.value))}>
          {RATING_CEILINGS.map((choice) => (
            <option key={choice.value} value={choice.value}>
              {choice.label}
            </option>
          ))}
        </Select>
        <div className="pt-7">
          <Toggle label="Also show unrated titles" checked={value.allow_unrated} onChange={(allow) => set("allow_unrated", allow)} />
        </div>
      </div>
      <Toggle
        label="Curated: only what's tagged for this profile"
        hint="Tag titles, channels and albums from their pages (For profiles)."
        checked={value.curated}
        onChange={(curated) => set("curated", curated)}
      />
      {libraries.isPending ? (
        <LoadingState label="Loading libraries…" />
      ) : libraries.isError ? (
        <ErrorState title="The libraries couldn't be loaded" message="Retry before choosing which this profile may see." onRetry={() => void libraries.refetch()} />
      ) : libraries.data.length > 1 ? (
        <fieldset className="space-y-2">
          <legend className="text-sm font-medium text-foreground">Libraries (none ticked: all of them)</legend>
          {libraries.data.map((library) => (
            <Checkbox
              key={library.id}
              label={library.name}
              checked={value.library_ids.includes(library.id)}
              onChange={(on) =>
                set("library_ids", on ? [...value.library_ids, library.id] : value.library_ids.filter((id) => id !== library.id))
              }
            />
          ))}
        </fieldset>
      ) : null}
      <fieldset className="space-y-3">
        <legend className="text-sm font-medium text-foreground">Playing</legend>
        <div className="grid gap-4 sm:grid-cols-2">
          <Select label="Up next starts after" value={value.up_next_seconds?.toString() ?? ""} onChange={(event) => set("up_next_seconds", number(event.target.value))}>
            <option value="">The usual 10 seconds</option>
            <option value="0">Straight away</option>
            <option value="5">5 seconds</option>
            <option value="20">20 seconds</option>
          </Select>
          <Select
            label="Ask “Still watching?” after"
            value={value.still_watching_after?.toString() ?? ""}
            onChange={(event) => set("still_watching_after", number(event.target.value))}
          >
            <option value="">3 episodes (the usual)</option>
            <option value="0">Never</option>
            <option value="2">2 episodes</option>
            <option value="5">5 episodes</option>
          </Select>
        </div>
        <div className="flex flex-wrap gap-6">
          <Toggle label="Always skip intros" checked={value.always_skip_intro} onChange={(on) => set("always_skip_intro", on)} />
          <Toggle label="Always skip credits" checked={value.always_skip_credits} onChange={(on) => set("always_skip_credits", on)} />
        </div>
      </fieldset>
    </div>
  );
}
