import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Pin, RefreshCw, RotateCcw } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { formatBytes } from "@/lib/bytes";
import { YOUTUBE_DOWNLOAD_STATE_LABELS, YOUTUBE_DOWNLOAD_STATE_TONES } from "@/lib/libraries";
import { relativeTime } from "@/lib/time";
import { useFormMutation } from "@/hooks/useFormMutation";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { DisclosureButton } from "@/components/ui/DisclosureButton";
import { FormError } from "@/components/ui/Form";
import { IconButton } from "@/components/ui/IconButton";
import { QueryState } from "@/components/ui/PageState";
import { Toggle } from "@/components/ui/Toggle";
import { TrackingRulesForm } from "@/components/youtube/TrackingRulesForm";
import type { ChannelTracking as Tracking, TrackingRules } from "@/types";

/** A channel's following: its rules, when it was last checked, and its downloads. */
export function ChannelTracking({ channelId }: { channelId: string }) {
  const tracking = useQuery({
    queryKey: keys.youtube.tracking(channelId),
    queryFn: ({ signal }) => api.get<Tracking>(`/channels/${channelId}/tracking`, { signal }),
    refetchInterval: (query) => ((query.state.data?.downloads.downloading ?? 0) + (query.state.data?.downloads.queued ?? 0) > 0 ? 10_000 : false),
  });
  return (
    <QueryState query={tracking} errorMessage="Could not load this channel's following.">
      {(data) => <TrackingCard channelId={channelId} tracking={data} />}
    </QueryState>
  );
}

function TrackingCard({ channelId, tracking }: { channelId: string; tracking: Tracking }) {
  const queryClient = useQueryClient();
  const [open, setOpen] = useState(false);
  // What's being edited, from what's saved: a poll during a download moves the counts, not this.
  const [draft, setDraft] = useState<TrackingRules | null>(null);
  const rules = draft ?? tracking;
  const refresh = (data?: Tracking) => {
    if (data) queryClient.setQueryData(keys.youtube.tracking(channelId), data);
    void queryClient.invalidateQueries({ queryKey: keys.youtube.all });
  };
  const save = useFormMutation({
    fallback: "Couldn't save the rules.",
    mutationFn: (changes: Partial<Tracking>) => api.patch<Tracking>(`/channels/${channelId}/tracking`, changes),
    onSuccess: (data) => {
      setDraft(null);
      refresh(data);
    },
  });
  const poll = useMutation({ mutationFn: () => api.post(`/channels/${channelId}/tracking/poll`), onSuccess: () => refresh() });
  const retry = useMutation({
    mutationFn: (downloadId: string) => api.post(`/channels/${channelId}/tracking/downloads/${downloadId}/retry`),
    onSuccess: () => refresh(),
  });
  const keep = useMutation({
    mutationFn: ({ downloadId, kept }: { downloadId: string; kept: boolean }) =>
      api.patch<Tracking>(`/channels/${channelId}/tracking/downloads/${downloadId}`, { kept }),
    onSuccess: (data) => {
      refresh(data);
      void queryClient.invalidateQueries({ queryKey: keys.videos.all });
    },
  });
  const counts = tracking.downloads;

  return (
    <Card>
      <CardHeader
        title="Following on YouTube"
        description={
          tracking.tracked
            ? `Checked ${tracking.last_polled_at ? relativeTime(tracking.last_polled_at) : "not yet"} · ${counts.done} downloaded${counts.queued + counts.downloading ? ` · ${counts.queued + counts.downloading} on the way` : ""}${counts.failed ? ` · ${counts.failed} failed` : ""}`
            : "Not following: nothing new is fetched. What's downloaded stays."
        }
        actions={
          <>
            <Toggle label="Follow" checked={tracking.tracked} onChange={(value) => save.mutate({ tracked: value })} />
            {tracking.tracked ? (
              <Button variant="secondary" size="sm" onClick={() => poll.mutate()} disabled={poll.isPending || poll.isSuccess}>
                <RefreshCw className="h-4 w-4" aria-hidden />
                {poll.isSuccess ? "Checking…" : "Check now"}
              </Button>
            ) : null}
          </>
        }
      />
      <CardBody className="space-y-4">
        {tracking.last_poll_error ? <p className="text-sm text-negative">Last check failed: {tracking.last_poll_error}</p> : null}
        <DisclosureButton open={open} onToggle={() => setOpen((value) => !value)} label="Rules and downloads" />
        {open ? (
          <div className="space-y-6">
            <form
              className="space-y-4"
              onSubmit={(event) => {
                event.preventDefault();
                save.mutate(rules);
              }}
            >
              <TrackingRulesForm rules={rules} onChange={setDraft} firstTime={false} />
              <FormError message={save.errorMessage} />
              <Button type="submit" size="sm" disabled={save.isPending}>
                Save rules
              </Button>
            </form>
            {tracking.recent.length > 0 ? (
              <ul className="divide-y divide-border rounded-[var(--radius-card)] border border-border text-sm">
                {tracking.recent.map((row) => (
                  <li key={row.id} className="flex items-center gap-3 px-3 py-2">
                    <Badge tone={YOUTUBE_DOWNLOAD_STATE_TONES[row.state]}>{YOUTUBE_DOWNLOAD_STATE_LABELS[row.state]}</Badge>
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-foreground">
                        {row.title ?? row.youtube_id}
                        {row.kept ? <span className="ml-2 text-xs text-muted">Kept</span> : null}
                      </p>
                      {row.last_error || row.reason ? <p className="truncate text-xs text-muted">{row.last_error ?? row.reason}</p> : null}
                    </div>
                    {row.bytes ? <span className="shrink-0 text-xs tabular-nums text-muted">{formatBytes(row.bytes)}</span> : null}
                    {row.state === "done" && (row.kept || tracking.keep_last !== null) ? (
                      <IconButton
                        label={row.kept ? `Let ${row.title ?? row.youtube_id} go when it's old` : `Keep ${row.title ?? row.youtube_id}`}
                        aria-pressed={row.kept}
                        onClick={() => keep.mutate({ downloadId: row.id, kept: !row.kept })}
                        disabled={keep.isPending}
                      >
                        <Pin className={row.kept ? "h-4 w-4 fill-current text-primary" : "h-4 w-4"} aria-hidden />
                      </IconButton>
                    ) : null}
                    {row.state !== "queued" && row.state !== "downloading" ? (
                      <IconButton
                        label={
                          row.state === "failed"
                            ? `Try ${row.title ?? row.youtube_id} again`
                            : `Download ${row.title ?? row.youtube_id} again${row.state === "done" ? ", replacing the file" : ""}`
                        }
                        onClick={() => retry.mutate(row.id)}
                        disabled={retry.isPending}
                      >
                        <RotateCcw className="h-4 w-4" aria-hidden />
                      </IconButton>
                    ) : null}
                  </li>
                ))}
              </ul>
            ) : null}
          </div>
        ) : null}
      </CardBody>
    </Card>
  );
}
