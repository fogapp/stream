import { useState, type FormEvent } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "@/api/client";
import { useAuth } from "@/hooks/useAuth";
import { useFormMutation } from "@/hooks/useFormMutation";
import { keys } from "@/lib/queryKeys";
import { Button } from "@/components/ui/Button";
import { CopyField } from "@/components/ui/CopyField";
import { FormError, FormFooter } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { QueryState } from "@/components/ui/PageState";
import { SectionHeader } from "@/components/ui/SectionHeader";
import { Select } from "@/components/ui/Select";
import { Toggle } from "@/components/ui/Toggle";
import { ENCODER_LABELS } from "@/lib/encoders";
import { NTFY_PUSH_LABELS } from "@/lib/notifications";
import { formatHour } from "@/lib/optimized";
import type { GeneralSettings, NtfyTopic } from "@/types";

/** Settings › General: instance-wide knobs. Admins edit; everyone reads. */
export function General() {
  const settings = useQuery({
    queryKey: keys.settings.general(),
    queryFn: ({ signal }) => api.get<GeneralSettings>("/app_setting", { signal }),
  });

  return (
    <section className="space-y-4">
      <SectionHeader
        title="Webhook"
        description="Stream POSTs every notification as JSON to this URL, so a home-automation hub or chat bot can react."
      />
      <QueryState query={settings} errorMessage="Could not load settings.">
        {(current) => (
          <div className="space-y-8">
            <TimeZoneForm initial={current} />
            <WebhookForm initial={current} />
            <NtfyForm initial={current} />
            <TranscodeForm initial={current} />
            <OptimizeForm initial={current} />
            <TrailersToggle initial={current} />
          </div>
        )}
      </QueryState>
    </section>
  );
}

/**
 * The webhook's address is write-only, like a key: its path is usually the
 * secret (Home Assistant's webhook id). A saved one shows as where it goes;
 * an empty field keeps it, and Turn off clears it.
 */
function WebhookForm({ initial }: { initial: GeneralSettings }) {
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const [url, setUrl] = useState("");
  const save = useFormMutation({
    mutationFn: (webhookUrl: string) => api.patch<GeneralSettings>("/app_setting", { webhook_url: webhookUrl }),
    onSuccess: () => {
      setUrl("");
      return queryClient.invalidateQueries({ queryKey: keys.settings.all });
    },
    fallback: "Could not save the webhook",
  });
  const admin = user?.role === "admin";
  const saved = initial.webhook_url_set;
  const where = saved ? `Sends to ${initial.webhook_host ?? "the address saved"}.` : "Off.";

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    save.mutate(url);
  }

  return (
    <form onSubmit={onSubmit} className="max-w-xl space-y-4">
      <Input
        label="Webhook URL"
        name="webhook_url"
        type="url"
        autoComplete="off"
        placeholder={saved ? "Saved — enter a new one to replace it" : "http://homeassistant.lan:8123/api/webhook/stream"}
        value={url}
        onChange={(event) => setUrl(event.target.value)}
        disabled={!admin}
        hint={admin ? where : `${where} Only an admin can change this.`}
      />
      <FormError message={save.errorMessage} />
      {admin ? (
        <div className="flex gap-2">
          <FormFooter label="Save" pending={save.isPending} disabled={url.trim() === ""} />
          {saved ? (
            <Button type="button" variant="ghost" disabled={save.isPending} onClick={() => save.mutate("")}>
              Turn off
            </Button>
          ) : null}
        </div>
      ) : null}
    </form>
  );
}

/**
 * How many videos this server converts at once (PROPOSAL §6.3). Everything
 * else — playing as-is, repackaging, converting only the sound — is never
 * limited.
 */
function TranscodeForm({ initial }: { initial: GeneralSettings }) {
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const [limit, setLimit] = useState(initial.max_video_transcodes?.toString() ?? "");
  const save = useFormMutation({
    mutationFn: () => api.patch<GeneralSettings>("/app_setting", { max_video_transcodes: limit }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: keys.settings.all }),
    fallback: "Could not save the limit",
  });
  const admin = user?.role === "admin";
  const encoder =
    initial.encoder !== "software"
      ? ENCODER_LABELS[initial.encoder]
      : initial.avx2
        ? "the CPU (no hardware encoder found)"
        : "the CPU, without AVX2 (on Proxmox, setting the VM's CPU type to host roughly doubles conversion speed)";

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    save.mutate();
  }

  return (
    <form onSubmit={onSubmit} className="max-w-xl space-y-4">
      <SectionHeader
        title="Video conversion"
        description={`Converting video uses ${encoder}; HDR tone mapping uses ${initial.tone_mapping === "none" ? "nothing (it will look washed out)" : initial.tone_mapping}.`}
      />
      <Input
        label="Videos converted at once"
        inputMode="numeric"
        value={limit}
        onChange={(event) => setLimit(event.target.value.replace(/\D/g, "").slice(0, 1))}
        placeholder={`Automatic (${initial.default_max_video_transcodes})`}
        disabled={!admin}
        hint="Beyond this, pressing Play on another file that needs converting says so instead of starting. Leave blank for automatic."
      />
      <FormError message={save.errorMessage} />
      {admin ? <FormFooter label="Save" pending={save.isPending} /> : null}
    </form>
  );
}

/** The household's clock (PROPOSAL §7.7): what a Grid channel's 8pm means. */
function TimeZoneForm({ initial }: { initial: GeneralSettings }) {
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const [zone, setZone] = useState(initial.time_zone ?? "");
  const save = useFormMutation({
    mutationFn: () => api.patch<GeneralSettings>("/app_setting", { time_zone: zone }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: keys.settings.all }),
    fallback: "Could not save the time zone",
  });
  const admin = user?.role === "admin";
  return (
    <form
      className="max-w-xl space-y-4"
      onSubmit={(event) => {
        event.preventDefault();
        save.mutate();
      }}
    >
      <SectionHeader title="Time zone" description="The household's clock: when the Grid's channels air their programs. Changing it rebuilds their schedules." />
      <Select label="Time zone" value={zone} onChange={(event) => setZone(event.target.value)} disabled={!admin}>
        <option value="">The server's ({initial.server_time_zone})</option>
        {initial.time_zones.map((option) => (
          <option key={option.name} value={option.name}>
            {option.label}
          </option>
        ))}
      </Select>
      <FormError message={save.errorMessage} />
      {admin ? <FormFooter label="Save" pending={save.isPending} /> : null}
    </form>
  );
}

/** Trailers (PROPOSAL §7.1–7.2): fetched with yt-dlp into storage, never embedded. */
function TrailersToggle({ initial }: { initial: GeneralSettings }) {
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const [on, setOn] = useState(initial.fetch_trailers);
  const save = useFormMutation({
    mutationFn: (value: boolean) => api.patch<GeneralSettings>("/app_setting", { fetch_trailers: value }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: keys.settings.all }),
    fallback: "Could not save",
  });
  return (
    <div className="max-w-xl space-y-4">
      <SectionHeader title="Trailers" description="The official trailer TMDB names for each film and show, fetched into Stream's storage and played from there." />
      <Toggle
        label="Fetch trailers"
        hint="They play behind Home's hero, muted, and from a Trailer button on each title's page."
        checked={on}
        onChange={(value) => {
          setOn(value);
          save.mutate(value);
        }}
        disabled={user?.role !== "admin" || save.isPending}
      />
      <FormError message={save.errorMessage} />
    </div>
  );
}

const HOURS = Array.from({ length: 24 }, (_, hour) => hour);
const HEIGHTS = [720, 1080, 2160] as const;

/**
 * Optimized versions (PROPOSAL §5.5): H.264 copies made while nobody's
 * watching, so a file some device can't decode plays as-is there.
 */
function OptimizeForm({ initial }: { initial: GeneralSettings }) {
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const [automatic, setAutomatic] = useState(initial.optimize_automatically);
  const [start, setStart] = useState(String(initial.optimize_quiet_start_hour));
  const [end, setEnd] = useState(String(initial.optimize_quiet_end_hour));
  const [height, setHeight] = useState(String(initial.optimize_max_height));
  const [budget, setBudget] = useState(String(initial.optimize_budget_gb));
  const save = useFormMutation({
    mutationFn: () =>
      api.patch<GeneralSettings>("/app_setting", {
        optimize_automatically: automatic,
        optimize_quiet_start_hour: start,
        optimize_quiet_end_hour: end,
        optimize_max_height: height,
        optimize_budget_gb: budget,
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: keys.settings.all }),
    fallback: "Could not save optimized versions",
  });
  const admin = user?.role === "admin";

  return (
    <form
      onSubmit={(event) => {
        event.preventDefault();
        save.mutate();
      }}
      className="max-w-xl space-y-4"
    >
      <SectionHeader
        title="Optimized versions"
        description="An H.264 copy of a file some device can't decode, made while nobody's watching and played instead of converting live. Encoding stops whenever someone needs a live conversion."
      />
      <Toggle
        label="Optimize automatically"
        hint="Each night, files that no device seen this month plays without converting get an optimized version. Any file can also be optimized from its page."
        checked={automatic}
        onChange={setAutomatic}
        disabled={!admin}
      />
      <div className="grid gap-4 sm:grid-cols-2">
        <Select label="Quiet hours start" value={start} onChange={(event) => setStart(event.target.value)} disabled={!admin}>
          {HOURS.map((hour) => (
            <option key={hour} value={hour}>
              {formatHour(hour)}
            </option>
          ))}
        </Select>
        <Select
          label="Quiet hours end"
          value={end}
          onChange={(event) => setEnd(event.target.value)}
          disabled={!admin}
          hint={start === end ? "Same as the start: encoding may happen at any time." : undefined}
        >
          {HOURS.map((hour) => (
            <option key={hour} value={hour}>
              {formatHour(hour)}
            </option>
          ))}
        </Select>
        <Select label="Tallest picture" value={height} onChange={(event) => setHeight(event.target.value)} disabled={!admin}>
          {HEIGHTS.map((value) => (
            <option key={value} value={value}>
              {value === 2160 ? "4K (2160p)" : `${value}p`}
            </option>
          ))}
        </Select>
        <Input
          label="Space for them (GB)"
          inputMode="numeric"
          value={budget}
          onChange={(event) => setBudget(event.target.value.replace(/\D/g, "").slice(0, 6))}
          disabled={!admin}
          hint="On the cache volume. Past this, only versions an admin asks for are made."
        />
      </div>
      <FormError message={save.errorMessage} />
      {admin ? <FormFooter label="Save" pending={save.isPending} /> : null}
    </form>
  );
}

/** Where each profile's pushes go (PROPOSAL §7.4); every profile picks its own topic in Settings › Viewing. */
function NtfyForm({ initial }: { initial: GeneralSettings }) {
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const [url, setUrl] = useState(initial.ntfy_url ?? "");
  const save = useFormMutation({
    mutationFn: () => api.patch<GeneralSettings>("/app_setting", { ntfy_url: url }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: keys.settings.all }),
    fallback: "Could not save ntfy's address",
  });
  const admin = user?.role === "admin";
  return (
    <form
      onSubmit={(event) => {
        event.preventDefault();
        save.mutate();
      }}
      className="max-w-xl space-y-4"
    >
      <Input
        label="ntfy server"
        name="ntfy_url"
        type="url"
        placeholder="http://ntfy.lan"
        value={url}
        onChange={(event) => setUrl(event.target.value)}
        disabled={!admin}
        hint="Push notifications — new episodes, new videos — go here, to each profile's own topic."
      />
      <FormError message={save.errorMessage} />
      {admin ? <FormFooter label="Save" pending={save.isPending} /> : null}
      {initial.ntfy_topics.length > 0 ? <NtfyTopics topics={initial.ntfy_topics} /> : null}
    </form>
  );
}

/** The topics to subscribe to in the ntfy app: one per profile that picked one, and what arrives on it. */
function NtfyTopics({ topics }: { topics: NtfyTopic[] }) {
  const chosen = topics.filter((row) => row.topic);
  const unset = topics.filter((row) => !row.topic);
  return (
    <div className="space-y-3">
      <div>
        <h3 className="text-sm font-medium text-foreground">Topics to subscribe to</h3>
        <p className="text-xs text-muted">Each profile picks its own topic in Settings › Viewing; subscribe to it in the ntfy app on that person&apos;s phone.</p>
      </div>
      {chosen.length > 0 ? (
        <ul className="space-y-3">
          {chosen.map((row) => (
            <li key={row.profile_id} className="space-y-1">
              <p className="text-xs text-muted">
                <span className="font-medium text-foreground">{row.profile}</span> — {row.pushes.map((push) => NTFY_PUSH_LABELS[push]).join(", ")}
              </p>
              <CopyField value={row.topic ?? ""} />
            </li>
          ))}
        </ul>
      ) : (
        <p className="text-sm text-muted">No profile has picked a topic yet, so nothing is pushed.</p>
      )}
      {unset.length > 0 && chosen.length > 0 ? (
        <p className="text-xs text-muted">No topic yet, so no pushes: {unset.map((row) => row.profile).join(", ")}.</p>
      ) : null}
    </div>
  );
}
