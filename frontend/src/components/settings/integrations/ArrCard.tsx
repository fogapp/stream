import { useState, type FormEvent } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Trash2 } from "lucide-react";
import { api } from "@/api/client";
import { useFormMutation } from "@/hooks/useFormMutation";
import { keys } from "@/lib/queryKeys";
import { relativeTime } from "@/lib/time";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { CopyField } from "@/components/ui/CopyField";
import { FormError } from "@/components/ui/Form";
import { IconButton } from "@/components/ui/IconButton";
import { Input } from "@/components/ui/Input";
import { QueryState } from "@/components/ui/PageState";
import type { ArrWebhookSettings } from "@/types";

/** Sonarr & Radarr: the webhook to paste into Connect, and the path mappings between them and Stream. */
export function ArrCard() {
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
