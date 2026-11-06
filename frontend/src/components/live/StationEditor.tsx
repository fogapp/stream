import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Plus } from "lucide-react";
import { api } from "@/api/client";
import { BlockEditor } from "@/components/live/BlockEditor";
import { LayerList } from "@/components/live/LayerList";
import { WeekClock } from "@/components/live/WeekClock";
import { WeekPreview } from "@/components/live/WeekPreview";
import { Button } from "@/components/ui/Button";
import { ChipPicker } from "@/components/ui/ChipPicker";
import { FormError, FormFooter } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import { Toggle } from "@/components/ui/Toggle";
import { useDebouncedValue } from "@/hooks/useDebouncedValue";
import { dayStart, FILLER_LABELS, SNAP_OPTIONS, WEEKDAYS } from "@/lib/live";
import { keys } from "@/lib/queryKeys";
import { EMPTY_BASE, newBlock, type StationDraft } from "@/lib/stationDraft";
import {
  STATION_FILLERS,
  type StationFiller,
  type StationOptions,
  type StationPreview,
} from "@/types";

/** Monday of this week, for placing specials on the clock. */
function mondayOf(time: number): Date {
  const date = new Date(time);
  const day = (date.getUTCDay() + 6) % 7;
  return new Date(
    Date.UTC(
      date.getUTCFullYear(),
      date.getUTCMonth(),
      date.getUTCDate() - day,
    ),
  );
}

/**
 * A channel's editor (PROPOSAL §7.7): its number and name, what airs
 * between programs, and its programming — the week's clock of dayparts,
 * appointments and specials over the base mix — with the next seven days
 * as saving would schedule them, and what's worth knowing about them.
 */
export function StationEditor({
  stationId,
  initial,
  options,
  pending,
  error,
  submitLabel,
  onSubmit,
  onCancel,
}: {
  stationId: string | null;
  initial: StationDraft;
  options: StationOptions;
  pending: boolean;
  error: string | null;
  submitLabel: string;
  onSubmit: (draft: StationDraft) => void;
  onCancel: () => void;
}) {
  const [draft, setDraft] = useState(initial);
  const [picked, setSelected] = useState<number>(0);
  const [appointment, setAppointment] = useState<Appointment | null>(null);
  // Showing a stream (PROPOSAL §7.8): no programming to edit, nothing to preview.
  const stream = Boolean(draft.live_stream_id);
  const set = <K extends keyof StationDraft>(key: K, value: StationDraft[K]) =>
    setDraft((current) => ({ ...current, [key]: value }));
  const blocks = draft.blocks.some((block) => block.layer === "base")
    ? draft.blocks
    : [EMPTY_BASE, ...draft.blocks];
  // The block picked, or the first once it's gone.
  const selected = picked < blocks.length ? picked : 0;
  const block = blocks[selected] ?? blocks[0] ?? EMPTY_BASE;
  const update = (index: number, next: (typeof blocks)[number]) =>
    set(
      "blocks",
      blocks.map((existing, at) => (at === index ? next : existing)),
    );
  const add = (made: (typeof blocks)[number]) => {
    set("blocks", [...blocks, made]);
    setSelected(blocks.length);
  };
  const move = (from: number, to: number) => {
    const next = [...blocks];
    const [moved] = next.splice(from, 1);
    if (!moved) return;
    next.splice(to, 0, moved);
    set("blocks", next);
    setSelected((current) =>
      current === from
        ? to
        : current > from && current <= to
          ? current - 1
          : current < from && current >= to
            ? current + 1
            : current,
    );
  };

  const debounced = useDebouncedValue(draft, 700);
  const previewBody = useMemo(
    () => ({
      ...debounced,
      station_id: stationId ?? undefined,
      number: debounced.number || "0",
      name: debounced.name || "Preview",
    }),
    [debounced, stationId],
  );
  const preview = useQuery({
    queryKey: keys.live.preview(previewBody),
    // A preview edited past is dropped, not left planning a week server-side.
    queryFn: ({ signal }) => api.post<StationPreview>("/stations/preview", previewBody, { signal }),
    placeholderData: (previous) => previous,
    staleTime: Infinity,
    enabled: !stream,
  });
  const today = dayStart(Date.now(), options.time_zone);
  const monday = useMemo(() => mondayOf(Date.now()), []);
  const channels = options.youtube_channels.map((channel) => ({
    value: channel.id,
    label: channel.title,
  }));

  return (
    <form
      className="space-y-6"
      onSubmit={(event) => {
        event.preventDefault();
        onSubmit({ ...draft, blocks });
      }}
    >
      <section className="space-y-4 rounded-[var(--radius-card)] border border-border bg-surface p-4">
        <div className="grid gap-4 sm:grid-cols-[8rem_1fr_8rem]">
          <Input
            label="Number"
            value={draft.number}
            onChange={(event) => set("number", event.target.value)}
            placeholder="4"
            required
            inputMode="decimal"
          />
          <Input
            label="Name"
            value={draft.name}
            onChange={(event) => set("name", event.target.value)}
            placeholder="Sitcoms"
            required
          />
          <Input
            label="Call sign"
            value={draft.call_sign}
            onChange={(event) => set("call_sign", event.target.value)}
            placeholder="WSTR"
            maxLength={8}
          />
        </div>
        {options.live_streams.length > 0 ? (
          <Select
            label="Shows"
            value={draft.live_stream_id ?? ""}
            onChange={(event) => set("live_stream_id", event.target.value || null)}
            hint={
              options.live_streams.find((live) => live.id === draft.live_stream_id)?.mlb_team
                ? "The team's games on MLB.tv as they're played; between games, tuning in says they aren't playing."
                : stream
                  ? "The stream, all day: one program in the guide, and nothing to schedule."
                  : undefined
            }
          >
            <option value="">Programming from the library</option>
            {options.live_streams.some((live) => !live.mlb_team) ? (
              <optgroup label="Cameras and streams">
                {options.live_streams
                  .filter((live) => !live.mlb_team)
                  .map((live) => (
                    <option key={live.id} value={live.id}>
                      {live.name} (live)
                    </option>
                  ))}
              </optgroup>
            ) : null}
            {options.live_streams.some((live) => live.mlb_team) ? (
              <optgroup label="MLB.tv teams">
                {options.live_streams
                  .filter((live) => live.mlb_team)
                  .map((live) => (
                    <option key={live.id} value={live.id}>
                      {live.name}
                    </option>
                  ))}
              </optgroup>
            ) : null}
          </Select>
        ) : null}
        {stream ? null : (
          <>
          <div className="grid gap-4 sm:grid-cols-3">
            <Select
              label="Programs start"
              value={draft.snap_minutes}
              onChange={(event) =>
                set("snap_minutes", Number(event.target.value))
              }
            >
              {SNAP_OPTIONS.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </Select>
            <Select
              label="Between programs"
              value={draft.filler}
              onChange={(event) =>
                set("filler", event.target.value as StationFiller)
              }
            >
              {STATION_FILLERS.map((filler) => (
                <option key={filler} value={filler}>
                  {FILLER_LABELS[filler]}
                </option>
              ))}
            </Select>
            <Input
              label="Don't repeat within (days)"
              type="number"
              min={0}
              max={30}
              value={draft.no_repeat_days}
              onChange={(event) =>
                set("no_repeat_days", Number(event.target.value) || 0)
              }
            />
          </div>
          {draft.filler !== "slate" ? (
            <Toggle
              label="Breaks inside programs"
              hint="Programs with chapters break at them (and after a cold open), with the filler in the breaks instead of all at the end."
              checked={draft.breaks}
              onChange={(on) => set("breaks", on)}
            />
          ) : null}
          {options.mlb_teams.length > 0 ? (
            <ChipPicker
              label="Baseball"
              hint="Whenever one of these teams plays, the game is on this channel, from first pitch to the last out, with the programming around it. Two playing at once: the one listed first."
              placeholder="Add a team…"
              options={options.mlb_teams.map((team) => ({
                value: String(team.id),
                label: team.name,
              }))}
              selected={draft.mlb_team_ids.map(String)}
              onChange={(ids) => set("mlb_team_ids", ids.map(Number))}
            />
          ) : null}
          {draft.filler === "videos" ? (
            <ChipPicker
              label="From these YouTube channels"
              hint="Their videos up to 15 minutes long fill the time between programs."
              options={channels}
              selected={draft.filler_channel_ids}
              onChange={(ids) => set("filler_channel_ids", ids)}
            />
          ) : null}
          </>
        )}
      </section>

      {stream ? null : (
        <>
          <section className="space-y-4 rounded-[var(--radius-card)] border border-border bg-surface p-4">
            <div>
              <h2 className="font-semibold">Programming</h2>
              <p className="text-sm text-muted">
                Top wins: specials, then appointments, then dayparts, then the mix —
                and within a kind, the one higher in the list. Times in{" "}
                {options.time_zone}. Double-click the clock to add a daypart.
              </p>
            </div>

            <div className="grid gap-4 lg:grid-cols-[15rem_minmax(0,1fr)] 2xl:grid-cols-[15rem_minmax(0,1.15fr)_minmax(0,1fr)]">
              <div className="space-y-3">
                <LayerList
                  blocks={blocks}
                  selected={selected}
                  onSelect={setSelected}
                  onMove={move}
                  addControls={{
                    special: (
                      <Button
                        type="button"
                        size="sm"
                        variant="ghost"
                        onClick={() => {
                          const date = new Date(Date.now() + 86_400_000)
                            .toISOString()
                            .slice(0, 10);
                          add({
                            ...newBlock("special", 127, 0, 1440),
                            name: "Special",
                            starts_on: date,
                            ends_on: date,
                          });
                        }}
                      >
                        <Plus className="h-4 w-4" aria-hidden />
                        Special
                      </Button>
                    ),
                    appointment: (
                      <Button
                        type="button"
                        size="sm"
                        variant="ghost"
                        onClick={() =>
                          setAppointment({
                            show: [],
                            day: 6,
                            start: "20:00",
                            length: 60,
                          })
                        }
                      >
                        <Plus className="h-4 w-4" aria-hidden />
                        Appointment
                      </Button>
                    ),
                    daypart: (
                      <Button
                        type="button"
                        size="sm"
                        variant="ghost"
                        onClick={() =>
                          add({
                            ...newBlock("daypart", 0b0011111, 19 * 60, 23 * 60),
                            name: "Primetime",
                          })
                        }
                      >
                        <Plus className="h-4 w-4" aria-hidden />
                        Daypart
                      </Button>
                    ),
                  }}
                  addForms={{
                    appointment: appointment ? (
                      <AppointmentForm
                        appointment={appointment}
                        shows={options.shows}
                        onChange={setAppointment}
                        onAdd={(next) => {
                          add(next);
                          setAppointment(null);
                        }}
                        onCancel={() => setAppointment(null)}
                      />
                    ) : null,
                  }}
                />
              </div>
              <WeekClock
                blocks={blocks}
                selected={selected}
                onSelect={setSelected}
                onChange={update}
                onAdd={(day, minute) =>
                  add(newBlock("daypart", 1 << day, minute, minute + 60))
                }
                weekStart={monday}
              />
              <div className="rounded-[var(--radius-card)] border border-border p-4 lg:col-span-2 2xl:col-span-1">
                <BlockEditor
                  key={selected}
                  block={block}
                  options={options}
                  onChange={(next) => update(selected, next)}
                  onRemove={() => {
                    set(
                      "blocks",
                      blocks.filter((_, index) => index !== selected),
                    );
                    setSelected(0);
                  }}
                />
              </div>
            </div>
          </section>

          <section className="space-y-3 rounded-[var(--radius-card)] border border-border bg-surface p-4">
            <div>
              <h2 className="font-semibold">The next seven days</h2>
              <p className="text-sm text-muted">
                As saving would schedule them. The program on now stays as it is.
              </p>
            </div>
            {preview.isError && !preview.data ? (
              <p className="text-sm text-muted">
                The preview couldn't be worked out — check the settings above.
              </p>
            ) : (
              <WeekPreview
                preview={preview.data}
                blocks={blocks}
                timeZone={options.time_zone}
                dayStart={today}
                pending={preview.isFetching}
              />
            )}
          </section>
        </>
      )}

      <FormError message={error} />
      <FormFooter label={submitLabel} pending={pending} onCancel={onCancel} />
    </form>
  );
}

interface Appointment {
  show: string[];
  day: number;
  start: string;
  length: number;
}

/** One show at one time each week: the block it makes is the show's, named after it. */
function AppointmentForm({
  appointment,
  shows,
  onChange,
  onAdd,
  onCancel,
}: {
  appointment: Appointment;
  shows: { id: string; title: string; year: number | null }[];
  onChange: (appointment: Appointment) => void;
  onAdd: (block: ReturnType<typeof newBlock>) => void;
  onCancel: () => void;
}) {
  const choose = () => {
    const [showId] = appointment.show;
    const [hours, minutes] = appointment.start.split(":").map(Number);
    const start = (hours ?? 20) * 60 + (minutes ?? 0);
    const title = shows.find((show) => show.id === showId)?.title ?? null;
    onAdd({
      ...newBlock("appointment", 1 << appointment.day, start, (start + appointment.length) % 1440 || 1440),
      name: title,
      source: { kinds: ["episode"], show_ids: showId ? [showId] : [] },
    });
  };
  return (
    <div className="space-y-3 rounded-[var(--radius-card)] border border-border bg-surface-raised p-3">
      <ChipPicker
        label="Show"
        options={shows.map((show) => ({ value: show.id, label: show.title, hint: show.year ? String(show.year) : undefined }))}
        selected={appointment.show}
        onChange={(show) => onChange({ ...appointment, show: show.slice(-1) })}
      />
      <Select label="Day" value={appointment.day} onChange={(event) => onChange({ ...appointment, day: Number(event.target.value) })}>
        {WEEKDAYS.map((day, index) => (
          <option key={day} value={index}>
            {day}
          </option>
        ))}
      </Select>
      <Input label="At" type="time" step={300} value={appointment.start} onChange={(event) => onChange({ ...appointment, start: event.target.value })} />
      <Select label="For" value={appointment.length} onChange={(event) => onChange({ ...appointment, length: Number(event.target.value) })}>
        {[30, 60, 90, 120].map((minutes) => (
          <option key={minutes} value={minutes}>
            {minutes < 60 ? `${minutes} min` : `${minutes / 60} hr`}
          </option>
        ))}
      </Select>
      <div className="flex gap-2 pt-1">
        <Button type="button" disabled={appointment.show.length === 0} onClick={choose}>
          Add
        </Button>
        <Button type="button" variant="ghost" onClick={onCancel}>
          Cancel
        </Button>
      </div>
    </div>
  );
}
