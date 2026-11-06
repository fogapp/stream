import { useState, type FormEvent } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Trash2 } from "lucide-react";
import { api } from "@/api/client";
import { useAuth } from "@/hooks/useAuth";
import { useConnectionSettings } from "@/hooks/useConnectionSettings";
import { useFormMutation } from "@/hooks/useFormMutation";
import { useTestConnection } from "@/hooks/useTestConnection";
import { hookQuery } from "@/lib/queries";
import { keys } from "@/lib/queryKeys";
import { relativeTime } from "@/lib/time";
import { ConnectionCard } from "@/components/settings/ConnectionCard";
import { ConnectionTestLine, TestResultLine } from "@/components/settings/TestResultLine";
import { Button } from "@/components/ui/Button";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { CopyField } from "@/components/ui/CopyField";
import { IconButton } from "@/components/ui/IconButton";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { FormError } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { MutationForm } from "@/components/ui/MutationForm";
import { ErrorState, QueryState } from "@/components/ui/PageState";
import { SecretInput } from "@/components/ui/SecretInput";
import { Select } from "@/components/ui/Select";
import { Toggle } from "@/components/ui/Toggle";
import { WHISPER_API_KINDS, type ArrWebhookSettings, type ImmichSettings, type MlbSettings, type NbaSettings, type OpenSubtitlesSettings, type TmdbSettings, type TraktSettings, type WhisperApiKind, type WhisperSettings } from "@/types";
import { WHISPER_API_KIND_OPTIONS } from "@/lib/whisper";

/** Settings › Integrations: the services Stream talks to. TMDB first; Sonarr, Radarr, Immich and Plex join it. */
export function Integrations() {
  const { user } = useAuth();
  const settings = useQuery({ queryKey: keys.tmdb.settings(), queryFn: ({ signal }) => api.get<TmdbSettings>("/tmdb_setting", { signal }) });
  return (
    <div className="space-y-6">
      <QueryState query={settings} errorMessage="Could not load integrations.">
        {(tmdb) => <TmdbCard settings={tmdb} />}
      </QueryState>
      {user?.role === "admin" ? <ArrCard /> : null}
      {user?.role === "admin" ? <HookCard /> : null}
      {user?.role === "admin" ? <ImmichCard /> : null}
      {user?.role === "admin" ? <TraktCard /> : null}
      {user?.role === "admin" ? <OpenSubtitlesCard /> : null}
      {user?.role === "admin" ? <WhisperCard /> : null}
      {user?.role === "admin" ? <MlbCard /> : null}
      {user?.role === "admin" ? <NbaCard /> : null}
    </div>
  );
}

/**
 * Hook (PROPOSAL §7.9): connected by fog, never pasted here. Once it is, the
 * household asks it for films and shows from search; Test says who Hook
 * takes the person asking to be.
 */
function HookCard() {
  const status = useQuery(hookQuery());
  const test = useTestConnection("/hook/test", keys.hook.all);
  const connected = status.data?.available === true;

  return (
    <ConnectionCard
      title="Hook"
      setUp={connected}
      badge="Connected"
      test={connected ? test : null}
      description={
        connected
          ? "The household asks Hook for films and shows from search: the telescope beside the search field, or ⇧↵. A request is the asker's in Hook when Hook knows their email."
          : "Connect Hook's Library offer on Stream's Integrations tab in fog. fog sets Hook's address and token and redeploys Stream; nothing is pasted here. Then search can ask Hook for films and shows."
      }
    >
      {status.isError ? (
        <CardBody>
          <ErrorState message="Could not load whether Hook is connected." onRetry={() => void status.refetch()} />
        </CardBody>
      ) : test.result ? (
        <CardBody>
          <TestResultLine ok={test.result.ok} message={test.result.message} />
        </CardBody>
      ) : null}
    </ConnectionCard>
  );
}

/** Sonarr & Radarr: the webhook to paste into Connect, and the path mappings between them and Stream. */
function ArrCard() {
  const queryClient = useQueryClient();
  const settings = useQuery({ queryKey: keys.arr.settings(), queryFn: ({ signal }) => api.get<ArrWebhookSettings>("/arr_webhook", { signal }) });
  const regenerate = useMutation({
    mutationFn: () => api.post<ArrWebhookSettings>("/arr_webhook/regenerate"),
    onSuccess: (data) => queryClient.setQueryData(keys.arr.settings(), data),
  });
  const remove = useMutation({
    mutationFn: (id: string) => api.delete<ArrWebhookSettings>(`/arr_webhook/path_mappings/${id}`),
    onSuccess: (data) => queryClient.setQueryData(keys.arr.settings(), data),
  });

  return (
    <Card>
      <CardHeader
        title="Sonarr & Radarr"
        description="New downloads appear in seconds instead of at the next hourly scan. In each app: Settings › Connect › Webhook, On Import, On Upgrade, On Rename and On Delete, Method POST."
      />
      <QueryState query={settings} errorMessage="Could not load the webhook.">
        {(arr) => (
          <CardBody className="space-y-5">
            <div className="space-y-2">
              <p className="text-sm font-medium text-foreground">Webhook URL</p>
              <CopyField value={arr.url} />
              <div className="flex flex-wrap items-center gap-3">
                <ConfirmButton
                  variant="secondary"
                  onConfirm={() => regenerate.mutate()}
                  question="Replace the URL? Sonarr and Radarr stop reaching Stream until you paste the new one."
                >
                  New URL
                </ConfirmButton>
                <p className="text-xs text-muted">
                  {arr.last_received_at
                    ? `${arr.last_outcome ?? `${arr.last_source} ${arr.last_event}`} · ${relativeTime(arr.last_received_at)}`
                    : "Nothing received yet. Press Test in Sonarr or Radarr to check."}
                </p>
              </div>
            </div>
            <div className="space-y-2">
              <p className="text-sm font-medium text-foreground">Path mappings</p>
              <p className="text-xs text-muted">
                When Sonarr sees your shows at /tv and Stream sees them at /media/tv, map one to the other.
              </p>
              {arr.path_mappings.length > 0 ? (
                <ul className="divide-y divide-border rounded-[var(--radius-card)] border border-border">
                  {arr.path_mappings.map((mapping) => (
                    <li key={mapping.id} className="flex items-center gap-3 px-3 py-2 font-mono text-sm">
                      <span className="min-w-0 flex-1 break-all">
                        {mapping.remote_prefix} <span className="text-muted">→</span> {mapping.local_prefix}
                      </span>
                      <IconButton label="Remove mapping" onClick={() => remove.mutate(mapping.id)}>
                        <Trash2 className="h-4 w-4" aria-hidden />
                      </IconButton>
                    </li>
                  ))}
                </ul>
              ) : null}
              <MappingForm />
            </div>
          </CardBody>
        )}
      </QueryState>
    </Card>
  );
}

function MappingForm() {
  const queryClient = useQueryClient();
  const [remote, setRemote] = useState("");
  const [local, setLocal] = useState("");
  const add = useFormMutation({
    mutationFn: () =>
      api.post<ArrWebhookSettings>("/arr_webhook/path_mappings", { path_mapping: { remote_prefix: remote, local_prefix: local } }),
    onSuccess: (data) => {
      queryClient.setQueryData(keys.arr.settings(), data);
      setRemote("");
      setLocal("");
    },
    fallback: "Could not add the mapping",
  });

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    add.mutate();
  }

  return (
    <form onSubmit={onSubmit} className="space-y-2">
      <div className="flex flex-col gap-2 sm:flex-row sm:items-end">
        <Input label="Sonarr/Radarr path" className="font-mono" placeholder="/tv" value={remote} onChange={(event) => setRemote(event.target.value)} />
        <Input label="Stream path" className="font-mono" placeholder="/media/tv" value={local} onChange={(event) => setLocal(event.target.value)} />
        <Button type="submit" variant="secondary" disabled={add.isPending || !remote.trim() || !local.trim()}>
          Add
        </Button>
      </div>
      <FormError message={add.errorMessage} />
    </form>
  );
}

function TmdbCard({ settings }: { settings: TmdbSettings }) {
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const admin = user?.role === "admin";
  const [key, setKey] = useState("");
  const test = useTestConnection("/tmdb_setting/test", keys.tmdb.all);
  const save = useFormMutation({
    mutationFn: () => api.patch<TmdbSettings>("/tmdb_setting", { tmdb_setting: { api_key: key } }),
    onSuccess: () => {
      setKey("");
      queryClient.invalidateQueries({ queryKey: keys.tmdb.all });
    },
    fallback: "Could not save the key",
  });

  return (
    <ConnectionCard
      title="TMDB"
      setUp={settings.configured}
      badge="Connected"
      test={admin && settings.configured ? test : null}
      description="Titles, artwork, cast and episode lists. Without a key, files still play under their file names."
    >
      <CardBody className="space-y-4">
        <ConnectionTestLine test={test} stored={settings} />
        {admin ? (
          <MutationForm mutation={save} label="Save key" disabled={!key.trim()}>
            <SecretInput
              label={settings.configured ? "Replace the key" : "API key or read access token"}
              value={key}
              onChange={(event) => setKey(event.target.value)}
              saved={settings.configured}
              placeholder="From themoviedb.org › Settings › API"
              hint="Either TMDB credential works. Adding the first key re-matches everything filed so far."
            />
          </MutationForm>
        ) : null}
      </CardBody>
    </ConnectionCard>
  );
}

/** Whisper: speech to text for channel videos without subtitles (PROPOSAL §5.5). */
function WhisperCard() {
  const { settings, test, current, saved } = useConnectionSettings<WhisperSettings>("/whisper_setting", keys.whisper);
  const [url, setUrl] = useState<string | null>(null);
  const [apiKind, setApiKind] = useState<WhisperApiKind | null>(null);
  const [model, setModel] = useState<string | null>(null);
  const [apiKey, setApiKey] = useState("");
  const save = useFormMutation({
    mutationFn: () =>
      api.patch<WhisperSettings>("/whisper_setting", {
        whisper_setting: {
          url: url ?? current?.url ?? "",
          api_kind: apiKind ?? current?.api_kind ?? "asr_webservice",
          model: model ?? current?.model ?? "",
          api_key: apiKey,
        },
      }),
    onSuccess: (data) => {
      setApiKey("");
      saved(data);
    },
    fallback: "Could not save Whisper's settings",
  });
  const toggle = useMutation({
    mutationFn: (enabled: boolean) => api.patch<WhisperSettings>("/whisper_setting", { whisper_setting: { enabled } }),
    onSuccess: saved,
  });
  const kind = apiKind ?? current?.api_kind ?? "asr_webservice";

  return (
    <ConnectionCard
      title="Whisper"
      setUp={current !== null}
      enabled={current?.enabled}
      test={current ? test : null}
      description="Transcribes channel videos that have no subtitles, so what they say can be searched and captioned. Optional."
    >
      <CardBody className="space-y-4">
        {current ? (
          <>
            <ConnectionTestLine test={test} stored={current} />
            <Toggle label="Transcribe new videos" checked={current.enabled} onChange={(enabled) => toggle.mutate(enabled)} />
          </>
        ) : null}
        <QueryState query={settings} errorMessage="Could not load Whisper's settings.">
          {() => (
            <MutationForm mutation={save} label="Save">
              <Input
                label="Address"
                value={url ?? current?.url ?? ""}
                onChange={(event) => setUrl(event.target.value)}
                placeholder="http://whisper:9000"
                hint="fog's Whisper app answers on port 9000."
              />
              <Select label="Kind of server" value={kind} onChange={(event) => setApiKind(event.target.value as WhisperApiKind)}>
                {WHISPER_API_KINDS.map((option) => (
                  <option key={option} value={option}>
                    {WHISPER_API_KIND_OPTIONS[option].label}
                  </option>
                ))}
              </Select>
              {kind === "openai" ? (
                <>
                  <Input label="Model" value={model ?? current?.model ?? ""} onChange={(event) => setModel(event.target.value)} placeholder="whisper-1" />
                  <SecretInput
                    label="API key"
                    value={apiKey}
                    onChange={(event) => setApiKey(event.target.value)}
                    saved={Boolean(current?.api_key_set)}
                    placeholder="If the server needs one"
                  />
                </>
              ) : null}
            </MutationForm>
          )}
        </QueryState>
      </CardBody>
    </ConnectionCard>
  );
}

/** OpenSubtitles: missing subtitle languages for movies and episodes (PROPOSAL §5.5). */
function OpenSubtitlesCard() {
  const { settings, test, current, saved } = useConnectionSettings<OpenSubtitlesSettings>("/open_subtitles_setting", keys.openSubtitles);
  const [apiKey, setApiKey] = useState("");
  const [username, setUsername] = useState<string | null>(null);
  const [password, setPassword] = useState("");
  const [languages, setLanguages] = useState<string | null>(null);
  const save = useFormMutation({
    mutationFn: () =>
      api.patch<OpenSubtitlesSettings>("/open_subtitles_setting", {
        open_subtitles_setting: {
          api_key: apiKey,
          username: username ?? current?.username ?? "",
          password,
          languages: (languages ?? current?.languages.join(", ") ?? "en").split(",").map((code) => code.trim()),
        },
      }),
    onSuccess: (data) => {
      setApiKey("");
      setPassword("");
      saved(data);
    },
    fallback: "Could not save OpenSubtitles' settings",
  });
  const toggle = useMutation({
    mutationFn: (enabled: boolean) => api.patch<OpenSubtitlesSettings>("/open_subtitles_setting", { open_subtitles_setting: { enabled } }),
    onSuccess: saved,
  });

  return (
    <ConnectionCard
      title="OpenSubtitles"
      setUp={current !== null}
      enabled={current?.enabled}
      test={current ? test : null}
      description="Fetches a movie's or episode's missing subtitle languages — the same file's first — and keeps them. Optional."
    >
      <CardBody className="space-y-4">
        {current ? (
          <>
            <ConnectionTestLine test={test} stored={current} />
            <Toggle label="Fetch missing subtitles" checked={current.enabled} onChange={(enabled) => toggle.mutate(enabled)} />
            {current.remaining_downloads !== null ? (
              <p className="text-sm text-muted">{current.remaining_downloads} downloads left today.</p>
            ) : null}
          </>
        ) : null}
        <QueryState query={settings} errorMessage="Could not load OpenSubtitles' settings.">
          {() => (
            <MutationForm mutation={save} label="Save" disabled={!current && !apiKey.trim()}>
              <SecretInput
                label="API key"
                value={apiKey}
                onChange={(event) => setApiKey(event.target.value)}
                saved={current !== null}
                placeholder="From opensubtitles.com › API consumers"
              />
              <div className="grid gap-4 sm:grid-cols-2">
                <Input label="Username" value={username ?? current?.username ?? ""} onChange={(event) => setUsername(event.target.value)} hint="Optional: more downloads a day." />
                <Input label="Password" type="password" autoComplete="off" value={password} onChange={(event) => setPassword(event.target.value)} />
              </div>
              <Input
                label="Languages"
                value={languages ?? current?.languages.join(", ") ?? "en"}
                onChange={(event) => setLanguages(event.target.value)}
                hint="Two-letter codes, separated by commas, e.g. en, fr"
              />
            </MutationForm>
          )}
        </QueryState>
      </CardBody>
    </ConnectionCard>
  );
}

/** Trakt: the household's registered Trakt API app, through which each adult profile links its own account (PROPOSAL §7.4). */
function TraktCard() {
  const queryClient = useQueryClient();
  const { settings, test, current, saved } = useConnectionSettings<TraktSettings>("/trakt_setting", keys.trakt);
  const [clientId, setClientId] = useState<string | null>(null);
  const [clientSecret, setClientSecret] = useState("");
  const save = useFormMutation({
    mutationFn: () =>
      api.patch<TraktSettings>("/trakt_setting", {
        trakt_setting: { client_id: clientId ?? current?.client_id ?? "", client_secret: clientSecret },
      }),
    onSuccess: (data) => {
      setClientSecret("");
      setClientId(null);
      saved(data);
    },
    fallback: "Could not save Trakt's settings",
  });
  const remove = useMutation({
    mutationFn: () => api.delete<TraktSettings>("/trakt_setting"),
    onSuccess: (data) => {
      saved(data);
      void queryClient.invalidateQueries({ queryKey: keys.trakt.account() });
    },
  });

  return (
    <ConnectionCard
      title="Trakt"
      setUp={current !== null}
      test={current ? test : null}
      description="Register an app at trakt.tv/oauth/applications (redirect URI urn:ietf:wg:oauth:2.0:oob), then each adult profile links its own account in Settings › Viewing."
    >
      <CardBody className="space-y-4">
        {current ? <ConnectionTestLine test={test} stored={current} /> : null}
        <QueryState query={settings} errorMessage="Could not load Trakt's settings.">
          {() => (
            <MutationForm mutation={save} label="Save" disabled={!current && (!clientSecret.trim() || !(clientId ?? "").trim())}>
              <Input label="Client ID" autoComplete="off" value={clientId ?? current?.client_id ?? ""} onChange={(event) => setClientId(event.target.value)} />
              <SecretInput label="Client secret" value={clientSecret} onChange={(event) => setClientSecret(event.target.value)} saved={current !== null} />
            </MutationForm>
          )}
        </QueryState>
        {current ? (
          <ConfirmButton onConfirm={() => remove.mutate()} disabled={remove.isPending} question="Remove Trakt and unlink every profile?">
            Remove Trakt
          </ConfirmButton>
        ) : null}
      </CardBody>
    </ConnectionCard>
  );
}

/** Immich: albums, people, places and capture times for home videos (PROPOSAL §5.4). Read-only. */
function ImmichCard() {
  const { settings, test, current, saved } = useConnectionSettings<ImmichSettings>("/immich_setting", keys.immich);
  const [url, setUrl] = useState<string | null>(null);
  const [apiKey, setApiKey] = useState("");
  const [immichPrefix, setImmichPrefix] = useState<string | null>(null);
  const [localPrefix, setLocalPrefix] = useState<string | null>(null);
  const save = useFormMutation({
    mutationFn: () =>
      api.patch<ImmichSettings>("/immich_setting", {
        immich_setting: {
          url: url ?? current?.url ?? "",
          api_key: apiKey,
          immich_path_prefix: immichPrefix ?? current?.immich_path_prefix ?? "",
          local_path_prefix: localPrefix ?? current?.local_path_prefix ?? "",
        },
      }),
    onSuccess: (data) => {
      setApiKey("");
      saved(data);
    },
    fallback: "Could not save Immich's settings",
  });
  const sync = useMutation({ mutationFn: () => api.post("/immich_setting/sync") });
  const counts = current?.last_sync_counts ?? {};

  return (
    <ConnectionCard
      title="Immich"
      setUp={current !== null}
      badge="Connected"
      test={current ? test : null}
      description="Brings home videos' albums, people, places and capture times across from Immich. Read-only; the videos themselves come from a Home videos library over the same folders."
      actions={
        current ? (
          <Button variant="secondary" size="sm" onClick={() => sync.mutate()} disabled={sync.isPending || sync.isSuccess}>
            {sync.isSuccess ? "Syncing…" : "Sync now"}
          </Button>
        ) : null
      }
    >
      <CardBody className="space-y-4">
        {current ? (
          <>
            <ConnectionTestLine test={test} stored={current} />
            <p className={current.last_sync_error ? "text-sm text-negative" : "text-sm text-muted"}>
              {current.last_sync_error
                ? `Last sync failed: ${current.last_sync_error}`
                : current.last_synced_at
                  ? `Synced ${relativeTime(current.last_synced_at)}: ${counts.clips_updated ?? 0} of ${counts.videos_in_immich ?? 0} videos matched, ${counts.albums ?? 0} albums, ${counts.people ?? 0} people.${counts.not_found_in_stream ? ` ${counts.not_found_in_stream} not found here — check the folder mapping.` : ""}`
                  : "Not synced yet."}
            </p>
          </>
        ) : null}
        <QueryState query={settings} errorMessage="Could not load Immich's settings.">
          {() => (
            <MutationForm mutation={save} label="Save" disabled={!current && !apiKey.trim()}>
              <Input label="Address" value={url ?? current?.url ?? ""} onChange={(event) => setUrl(event.target.value)} placeholder="http://immich:2283" />
              <SecretInput
                label="API key"
                value={apiKey}
                onChange={(event) => setApiKey(event.target.value)}
                saved={current !== null}
                placeholder="Immich › Account settings › API keys"
              />
              <div className="grid gap-4 sm:grid-cols-2">
                <Input
                  label="Immich sees the files at"
                  value={immichPrefix ?? current?.immich_path_prefix ?? ""}
                  onChange={(event) => setImmichPrefix(event.target.value)}
                  placeholder="/usr/src/app/upload"
                />
                <Input
                  label="Stream sees them at"
                  value={localPrefix ?? current?.local_path_prefix ?? ""}
                  onChange={(event) => setLocalPrefix(event.target.value)}
                  placeholder="/media/immich"
                />
              </div>
            </MutationForm>
          )}
        </QueryState>
      </CardBody>
    </ConnectionCard>
  );
}

/** MLB.tv: the account yt-dlp signs in with to play a game (PROPOSAL §7.8). Saving one puts Baseball in the sidebar. The password is write-only. */
function MlbCard() {
  const queryClient = useQueryClient();
  const { settings, test, current, saved } = useConnectionSettings<MlbSettings>("/mlb_setting", keys.mlb);
  const [username, setUsername] = useState<string | null>(null);
  const [password, setPassword] = useState("");
  const save = useFormMutation({
    mutationFn: () => api.patch<MlbSettings>("/mlb_setting", { mlb_setting: { username: username ?? current?.username ?? "", password } }),
    onSuccess: (data) => {
      setPassword("");
      saved(data);
      void queryClient.invalidateQueries({ queryKey: keys.baseball.all });
    },
    fallback: "Could not save the MLB.tv account",
  });
  const remove = useMutation({
    mutationFn: () => api.delete<MlbSettings>("/mlb_setting"),
    onSuccess: (data) => {
      setUsername(null);
      saved(data);
      void queryClient.invalidateQueries({ queryKey: keys.baseball.all });
    },
  });

  return (
    <ConnectionCard
      title="MLB.tv"
      setUp={current !== null}
      test={current ? test : null}
      description="Sign in, and Baseball in the sidebar shows every game and plays it. Blackouts in this server's area still apply."
      actions={
        current ? (
          <ConfirmButton onConfirm={() => remove.mutate()} question="Forget the MLB.tv account? Baseball leaves the sidebar and games stop playing until it's set again.">
            Forget
          </ConfirmButton>
        ) : null
      }
    >
      <CardBody className="space-y-4">
        <QueryState query={settings} errorMessage="Could not load the MLB.tv account.">
          {() => (
            <>
              {current ? <ConnectionTestLine test={test} stored={current} /> : null}
              <MutationForm mutation={save} label="Save" disabled={!current && !password}>
                <div className="grid gap-4 sm:grid-cols-2">
                  <Input
                    label="Email"
                    type="email"
                    autoComplete="off"
                    value={username ?? current?.username ?? ""}
                    onChange={(event) => setUsername(event.target.value)}
                  />
                  <SecretInput label="Password" value={password} onChange={(event) => setPassword(event.target.value)} saved={current !== null} />
                </div>
              </MutationForm>
            </>
          )}
        </QueryState>
      </CardBody>
    </ConnectionCard>
  );
}

/**
 * NBA League Pass (PROPOSAL §7.8): turning it on puts Basketball in the
 * sidebar. League Pass games are DRM-protected, so Stream can't play them
 * and keeps no NBA account: a game opens on NBA.com, where you sign in.
 */
function NbaCard() {
  const queryClient = useQueryClient();
  const { settings, test, current, saved } = useConnectionSettings<NbaSettings>("/nba_setting", keys.nba);
  const changed = (data: NbaSettings) => {
    saved(data);
    void queryClient.invalidateQueries({ queryKey: keys.basketball.all });
  };
  const turnOn = useFormMutation({
    mutationFn: () => api.patch<NbaSettings>("/nba_setting", { nba_setting: {} }),
    onSuccess: changed,
    fallback: "Could not turn on NBA League Pass",
  });
  const turnOff = useMutation({ mutationFn: () => api.delete<NbaSettings>("/nba_setting"), onSuccess: changed });

  return (
    <ConnectionCard
      title="NBA League Pass"
      setUp={current !== null}
      test={current ? test : null}
      description="Turn on, and Basketball in the sidebar shows every game with its score. League Pass games are copy-protected, so they play on NBA.com, where you sign in; Stream keeps no NBA password."
      actions={
        current ? (
          <ConfirmButton onConfirm={() => turnOff.mutate()} question="Turn off NBA League Pass? Basketball leaves the sidebar.">
            Turn off
          </ConfirmButton>
        ) : null
      }
    >
      <CardBody className="space-y-4">
        <QueryState query={settings} errorMessage="Could not load NBA League Pass.">
          {() =>
            current ? (
              <ConnectionTestLine test={test} stored={current} />
            ) : (
              <div className="space-y-3">
                <FormError message={turnOn.errorMessage} />
                <Button size="sm" onClick={() => turnOn.mutate()} disabled={turnOn.isPending}>
                  {turnOn.isPending ? "Turning on…" : "Turn on"}
                </Button>
              </div>
            )
          }
        </QueryState>
      </CardBody>
    </ConnectionCard>
  );
}
