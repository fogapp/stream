import { Input } from "@/components/ui/Input";
import { RadioCard } from "@/components/ui/Radio";
import { Select } from "@/components/ui/Select";
import { Toggle } from "@/components/ui/Toggle";
import { MAX_HEIGHTS } from "@/lib/libraries";
import type { TrackingRules } from "@/types";

export const DEFAULT_RULES: TrackingRules = {
  backfill: "recent",
  backfill_count: 5,
  backfill_since: null,
  keep_last: 5,
  skip_shorts: true,
  skip_live: true,
  title_filter: null,
  max_height: 1080,
  poll_every_hours: 1,
};

const POLL_OPTIONS = [1, 3, 6, 12, 24, 72, 168] as const;

/** How far back to fetch, what to keep, and what to skip (PROPOSAL §5.4). */
export function TrackingRulesForm({ rules, onChange, firstTime }: { rules: TrackingRules; onChange: (rules: TrackingRules) => void; firstTime: boolean }) {
  const set = <K extends keyof TrackingRules>(key: K, value: TrackingRules[K]) => onChange({ ...rules, [key]: value });
  return (
    <div className="space-y-5">
      {firstTime ? (
        <fieldset className="space-y-2">
          <legend className="mb-2 text-sm font-medium text-foreground">How far back to fetch</legend>
          <RadioCard
            name="backfill"
            checked={rules.backfill === "recent"}
            onChange={() => set("backfill", "recent")}
            label="The newest videos"
            hint={
              <span className="inline-flex items-center gap-2">
                <Input
                  aria-label="How many of the newest"
                  type="number"
                  min={1}
                  max={5000}
                  value={rules.backfill_count}
                  onChange={(event) => set("backfill_count", Number(event.target.value) || 1)}
                  className="w-24"
                />
                of them
              </span>
            }
          />
          <RadioCard name="backfill" checked={rules.backfill === "all"} onChange={() => set("backfill", "all")} label="Everything" hint="The whole channel. Can be a lot." />
          <RadioCard
            name="backfill"
            checked={rules.backfill === "since"}
            onChange={() => set("backfill", "since")}
            label="Everything since a date"
            hint={
              <Input
                aria-label="Since"
                type="date"
                value={rules.backfill_since ?? ""}
                onChange={(event) => set("backfill_since", event.target.value || null)}
                className="w-44"
              />
            }
          />
        </fieldset>
      ) : null}
      <div className="grid gap-4 sm:grid-cols-3">
        <Input
          label="Keep the newest"
          hint="Older downloads are deleted. Empty keeps everything."
          type="number"
          min={1}
          max={5000}
          placeholder="All"
          value={rules.keep_last ?? ""}
          onChange={(event) => set("keep_last", event.target.value ? Number(event.target.value) : null)}
        />
        <Select label="Best quality" value={rules.max_height} onChange={(event) => set("max_height", Number(event.target.value))}>
          {MAX_HEIGHTS.map((height) => (
            <option key={height} value={height}>
              {height === 2160 ? "4K" : `${height}p`}
            </option>
          ))}
        </Select>
        <Select label="Check for new videos" value={rules.poll_every_hours} onChange={(event) => set("poll_every_hours", Number(event.target.value))}>
          {POLL_OPTIONS.map((hours) => (
            <option key={hours} value={hours}>
              {hours === 1 ? "Every hour" : hours < 24 ? `Every ${hours} hours` : hours === 24 ? "Daily" : hours === 168 ? "Weekly" : `Every ${hours / 24} days`}
            </option>
          ))}
        </Select>
      </div>
      <Input
        label="Only titles matching"
        hint="A regular expression, ignoring case: full episode|part \d+. Empty fetches every video."
        placeholder="Every video"
        spellCheck={false}
        value={rules.title_filter ?? ""}
        onChange={(event) => set("title_filter", event.target.value || null)}
        className="font-mono"
      />
      <div className="flex flex-wrap gap-6">
        <Toggle label="Skip Shorts" checked={rules.skip_shorts} onChange={(value) => set("skip_shorts", value)} />
        <Toggle label="Skip livestreams" checked={rules.skip_live} onChange={(value) => set("skip_live", value)} />
      </div>
    </div>
  );
}
