import { useMutation } from "@tanstack/react-query";
import { api } from "@/api/client";
import { useConnectionSettings } from "@/hooks/useConnectionSettings";
import { useDraft } from "@/hooks/useDraft";
import { useFormMutation } from "@/hooks/useFormMutation";
import { keys } from "@/lib/queryKeys";
import { relativeTime } from "@/lib/time";
import { ConnectionCard } from "@/components/settings/ConnectionCard";
import { ConnectionTestLine } from "@/components/settings/TestResultLine";
import { Button } from "@/components/ui/Button";
import { CardBody } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { MutationForm } from "@/components/ui/MutationForm";
import { QueryState } from "@/components/ui/PageState";
import { SecretInput } from "@/components/ui/SecretInput";
import type { ImmichSettings } from "@/types";

/** Immich: albums, people, places and capture times for home videos (PROPOSAL §5.4). Read-only. */
export function ImmichCard() {
  const { settings, test, current, saved } = useConnectionSettings<ImmichSettings>("/immich_setting", keys.immich);
  const draft = useDraft(current, { url: "", api_key: "", immich_path_prefix: "", local_path_prefix: "" });
  const save = useFormMutation({
    mutationFn: () => api.patch<ImmichSettings>("/immich_setting", { immich_setting: draft.values() }),
    onSuccess: (data) => {
      draft.reset();
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
            <MutationForm mutation={save} label="Save" disabled={!current && !draft.value("api_key").trim()}>
              <Input label="Address" value={draft.value("url")} onChange={(event) => draft.set("url", event.target.value)} placeholder="http://immich:2283" />
              <SecretInput
                label="API key"
                value={draft.value("api_key")}
                onChange={(event) => draft.set("api_key", event.target.value)}
                saved={current !== null}
                placeholder="Immich › Account settings › API keys"
              />
              <div className="grid gap-4 sm:grid-cols-2">
                <Input
                  label="Immich sees the files at"
                  value={draft.value("immich_path_prefix")}
                  onChange={(event) => draft.set("immich_path_prefix", event.target.value)}
                  placeholder="/usr/src/app/upload"
                />
                <Input
                  label="Stream sees them at"
                  value={draft.value("local_path_prefix")}
                  onChange={(event) => draft.set("local_path_prefix", event.target.value)}
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
