import { useState, type FormEvent } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "@/api/client";
import { useFormMutation } from "@/hooks/useFormMutation";
import { useTestConnection } from "@/hooks/useTestConnection";
import { JOB_RUN_STATUS_LABELS, JOB_RUN_STATUS_TONES } from "@/lib/jobs";
import { keys } from "@/lib/queryKeys";
import { profilesQuery } from "@/lib/queries";
import { relativeTime } from "@/lib/time";
import { TestButton } from "@/components/settings/TestButton";
import { ConnectionTestLine } from "@/components/settings/TestResultLine";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { DisclosureButton } from "@/components/ui/DisclosureButton";
import { FormError, FormFooter } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { SecretInput } from "@/components/ui/SecretInput";
import { QueryState } from "@/components/ui/PageState";
import { Select } from "@/components/ui/Select";
import { Toggle } from "@/components/ui/Toggle";
import type { PlexConnectionInfo, PlexImportRun } from "@/types";

type Connected = Extract<PlexConnectionInfo, { connected: true }>;

/**
 * Settings › Import from Plex (PROPOSAL §7.4): connect read-only, say who is
 * who, look at a dry run, then import — and keep syncing while both run.
 */
export function PlexImport() {
  const connection = useQuery({
    queryKey: keys.plex.connection(),
    queryFn: ({ signal }) => api.get<PlexConnectionInfo>("/plex_connection", { signal }),
  });
  return (
    <QueryState query={connection} errorMessage="Could not load the Plex connection.">
      {(info) => (
        <div className="space-y-6">
          <ConnectCard connection={info} />
          {info.connected ? (
            <>
              <PeopleCard connection={info} />
              <RunsCard connection={info} />
            </>
          ) : null}
        </div>
      )}
    </QueryState>
  );
}

function ConnectCard({ connection }: { connection: PlexConnectionInfo }) {
  const queryClient = useQueryClient();
  const [url, setUrl] = useState(connection.connected ? connection.server_url : "");
  const [token, setToken] = useState("");
  const test = useTestConnection("/plex_connection/test", keys.plex.all);
  const save = useFormMutation({
    mutationFn: () => api.patch<PlexConnectionInfo>("/plex_connection", { plex_connection: { server_url: url, token } }),
    onSuccess: (data) => {
      queryClient.setQueryData(keys.plex.connection(), data);
      setToken("");
      test.run();
    },
    fallback: "Could not save the Plex server",
  });
  const disconnect = useMutation({
    mutationFn: () => api.delete("/plex_connection"),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: keys.plex.all }),
  });

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    save.mutate();
  }

  return (
    <Card>
      <CardHeader
        title={
          <span className="flex items-center gap-2">
            1. Your Plex server
            {connection.connected && connection.last_test_ok ? <Badge tone="success">Connected</Badge> : null}
          </span>
        }
        description="Stream only reads from Plex. Nothing there is changed, so both can run side by side until you switch."
        actions={
          connection.connected ? (
            <>
              <TestButton connection={test} />
              <ConfirmButton variant="ghost" onConfirm={() => disconnect.mutate()} question="Forget this Plex server? Imported history stays.">
                Disconnect
              </ConfirmButton>
            </>
          ) : null
        }
      />
      <CardBody className="space-y-4">
        {connection.connected ? (
          <ConnectionTestLine test={test} stored={connection} />
        ) : null}
        <form onSubmit={onSubmit} className="max-w-xl space-y-4">
          <Input
            label="Server address"
            placeholder="http://192.168.1.12:32400"
            value={url}
            onChange={(event) => setUrl(event.target.value)}
            required
          />
          <SecretInput
            label={connection.connected ? "Replace the token" : "Plex token"}
            value={token}
            onChange={(event) => setToken(event.target.value)}
            saved={Boolean(connection.connected)}
            placeholder="X-Plex-Token"
            hint="In Plex Web, open any item › ⋯ › Get Info › View XML; the token is the X-Plex-Token at the end of the address."
          />
          <FormError message={save.errorMessage} />
          <FormFooter label={connection.connected ? "Save" : "Connect"} pending={save.isPending} disabled={!url.trim() || (!connection.connected && !token.trim())} />
        </form>
      </CardBody>
    </Card>
  );
}

function PeopleCard({ connection }: { connection: Connected }) {
  const queryClient = useQueryClient();
  const profiles = useQuery(profilesQuery());
  const map = useMutation({
    mutationFn: ({ mappingId, profileId }: { mappingId: string; profileId: string }) =>
      api.patch<PlexConnectionInfo>(`/plex_connection/users/${mappingId}`, { profile_id: profileId }),
    onSuccess: (data) => {
      queryClient.setQueryData(keys.plex.connection(), data);
      void queryClient.invalidateQueries({ queryKey: keys.profiles.all });
    },
  });

  return (
    <Card>
      <CardHeader
        title="2. Who's who"
        description="Each Plex user's watch history goes to a Stream profile. Press Test above to refresh this list."
      />
      <CardBody>
        {connection.users.length === 0 ? (
          <p className="text-sm text-muted">Press Test to find the people in your Plex Home.</p>
        ) : (
          <QueryState query={profiles} errorMessage="Could not load profiles.">
            {(list) => (
              <ul className="divide-y divide-border">
                {connection.users.map((user) => (
                  <li key={user.id} className="flex flex-col gap-2 py-3 sm:flex-row sm:items-center sm:justify-between">
                    <p className="text-sm text-foreground">
                      {user.plex_name} {user.plex_admin ? <Badge>Owner</Badge> : null}
                    </p>
                    <div className="sm:w-64">
                      <Select
                        aria-label={`Stream profile for ${user.plex_name}`}
                        value={user.profile_id ?? ""}
                        onChange={(event) => map.mutate({ mappingId: user.id, profileId: event.target.value })}
                        disabled={map.isPending}
                      >
                        <option value="">Don't import</option>
                        {list.map((profile) => (
                          <option key={profile.id} value={profile.id}>
                            {profile.name}
                          </option>
                        ))}
                        <option value="new">New profile: {user.plex_name}</option>
                      </Select>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </QueryState>
        )}
      </CardBody>
    </Card>
  );
}

function RunsCard({ connection }: { connection: Connected }) {
  const queryClient = useQueryClient();
  const runs = useQuery({
    queryKey: keys.plex.imports(),
    queryFn: ({ signal }) => api.get<PlexImportRun[]>("/plex_imports", { signal }),
    refetchInterval: (query) => (query.state.data?.some((run) => run.status === "queued" || run.status === "running") ? 2_000 : false),
  });
  const start = useMutation({
    mutationFn: (dryRun: boolean) => api.post<PlexImportRun>("/plex_imports", { dry_run: dryRun }),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: keys.plex.imports() }),
  });
  const sync = useMutation({
    mutationFn: (enabled: boolean) => api.patch<PlexConnectionInfo>("/plex_connection", { plex_connection: { sync_enabled: enabled } }),
    onSuccess: (data) => queryClient.setQueryData(keys.plex.connection(), data),
  });
  const busy = runs.data?.some((run) => run.status === "queued" || run.status === "running") ?? false;
  const mapped = connection.users.some((user) => user.profile_id);

  return (
    <Card>
      <CardHeader
        title="3. Bring your history over"
        description="A dry run shows what would match and what wouldn't, and writes nothing. The import only ever adds or updates: a newer view in Stream always wins."
        actions={
          <>
            <Button variant="secondary" size="sm" onClick={() => start.mutate(true)} disabled={busy || !mapped}>
              Dry run
            </Button>
            <Button size="sm" onClick={() => start.mutate(false)} disabled={busy || !mapped}>
              Import
            </Button>
          </>
        }
      />
      <CardBody className="space-y-4">
        <Toggle
          label="Keep in sync"
          hint={`Every six hours, bring over anything watched in Plex since.${connection.last_synced_at ? ` Last synced ${relativeTime(connection.last_synced_at)}.` : ""}`}
          checked={connection.sync_enabled}
          onChange={(checked) => sync.mutate(checked)}
        />
        <QueryState query={runs} errorMessage="Could not load past runs.">
          {(list) =>
            list.length === 0 ? (
              <p className="text-sm text-muted">No runs yet. Start with a dry run.</p>
            ) : (
              <ul className="space-y-3">
                {list.map((run) => (
                  <RunRow key={run.id} run={run} />
                ))}
              </ul>
            )
          }
        </QueryState>
      </CardBody>
    </Card>
  );
}

function RunRow({ run }: { run: PlexImportRun }) {
  const [open, setOpen] = useState(false);
  const count = (key: string) => run.counts[key] ?? 0;
  const verb = run.dry_run ? "would import" : "imported";
  return (
    <li className="rounded-[var(--radius-card)] border border-border p-3 text-sm">
      <div className="flex flex-wrap items-center gap-2">
        <Badge tone={JOB_RUN_STATUS_TONES[run.status]}>{JOB_RUN_STATUS_LABELS[run.status]}</Badge>
        <span className="font-medium text-foreground">{run.dry_run ? "Dry run" : "Import"}</span>
        <span className="text-muted">{relativeTime(run.finished_at ?? run.created_at)}</span>
      </div>
      {run.error ? <p className="mt-2 text-negative">{run.error}</p> : null}
      {run.status === "succeeded" ? (
        <div className="mt-2 space-y-1 text-muted">
          <p>
            Matched {count("movies_matched")} of {count("movies_in_plex")} movies and {count("episodes_matched")} of{" "}
            {count("episodes_in_plex")} episodes.
          </p>
          <p>
            {verb} {count("watched_imported")} watched and {count("in_progress_imported")} in progress
            {count("newer_in_stream") ? `; ${count("newer_in_stream")} left alone because Stream has a newer view` : ""}
            {count("unchanged") ? `; ${count("unchanged")} already up to date` : ""}.
          </p>
          {count("ratings_imported") + count("collections_imported") + count("smart_collections_imported") + count("custom_fields_imported") +
            count("custom_pictures_imported") + count("playlists_imported") >
          0 ? (
            <p>
              Also {verb}{" "}
              {[
                count("ratings_imported") ? `${count("ratings_imported")} ratings` : null,
                count("collections_imported")
                  ? `${count("collections_imported")} collections (${count("collection_items_imported")} titles)`
                  : null,
                count("smart_collections_imported") ? `${count("smart_collections_imported")} smart collections (kept live as rules)` : null,
                count("playlists_imported") ? `${count("playlists_imported")} playlists` : null,
                count("custom_fields_imported") ? `${count("custom_fields_imported")} edited details` : null,
                count("custom_pictures_imported") ? `${count("custom_pictures_imported")} chosen posters and backgrounds` : null,
              ]
                .filter(Boolean)
                .join(", ")}
              {count("smart_collections_snapshotted")
                ? `; ${count("smart_collections_snapshotted")} smart collections brought as they stand today (their filters ask for things Stream's rules can't)`
                : ""}
              {count("custom_pictures_failed") ? `; ${count("custom_pictures_failed")} pictures couldn't be fetched` : ""}.
            </p>
          ) : null}
          {run.users.map((user) => (
            <p key={user.plex_name}>
              {user.plex_name} → {user.profile ?? "nobody"}
              {user.error ? <span className="text-negative"> — {user.error}</span> : null}
            </p>
          ))}
          {run.unmatched.length > 0 ? (
            <div>
              <DisclosureButton
                open={open}
                onToggle={() => setOpen((value) => !value)}
                label={`${run.unmatched.length} not found in Stream`}
              />
              {open ? (
                <ul className="mt-2 columns-1 gap-6 text-xs sm:columns-2">
                  {run.unmatched.map((item) => (
                    <li key={`${item.kind}-${item.title}`}>{item.title}</li>
                  ))}
                </ul>
              ) : null}
            </div>
          ) : null}
        </div>
      ) : null}
    </li>
  );
}
