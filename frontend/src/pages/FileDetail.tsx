import { useState, type FormEvent } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useParams } from "react-router-dom";
import { RefreshCw } from "lucide-react";
import { api } from "@/api/client";
import { useAuth } from "@/hooks/useAuth";
import { useFormMutation } from "@/hooks/useFormMutation";
import { formatBytes } from "@/lib/bytes";
import { formatClock } from "@/lib/format";
import { ANALYSIS_STATUS_LABELS, ANALYSIS_STATUS_TONES, ANALYSIS_STEP_LABELS, MEDIA_FILE_STATE_LABELS, MEDIA_FILE_STATE_TONES } from "@/lib/libraries";
import { PLAYBACK_METHOD_LABELS, PLAYBACK_METHOD_TONES } from "@/lib/playback";
import { keys } from "@/lib/queryKeys";
import { relativeTime } from "@/lib/time";
import { PageHeader } from "@/components/layout/PageHeader";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { FormError } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Fact, FactList } from "@/components/ui/FactList";
import { IconButton } from "@/components/ui/IconButton";
import { QueryState } from "@/components/ui/PageState";
import { OptimizedStatus } from "@/components/playback/OptimizedStatus";
import { MARKER_KINDS, type AnalysisStep, type MarkerKind, type MediaFileDetail, type MediaStreamInfo } from "@/types";

/** Everything Stream knows about one file (PROPOSAL §8.2). */
export function FileDetail() {
  const { id = "" } = useParams();
  const file = useQuery({
    queryKey: keys.mediaFiles.detail(id),
    queryFn: ({ signal }) => api.get<MediaFileDetail>(`/media_files/${id}`, { signal }),
    refetchInterval: (query) =>
      query.state.data?.analysis.some((run) => run.status === "running") || query.state.data?.optimized?.state === "encoding" ? 3_000 : false,
  });
  return (
    <QueryState query={file} errorMessage="Could not load this file.">
      {(detail) => <FilePage file={detail} />}
    </QueryState>
  );
}

function describe(stream: MediaStreamInfo): string {
  const parts: (string | null)[] = [stream.codec?.toUpperCase() ?? null, stream.profile];
  if (stream.kind === "video") {
    parts.push(stream.width && stream.height ? `${stream.width}×${stream.height}` : null);
    parts.push(stream.bit_depth ? `${stream.bit_depth}-bit` : null, stream.frame_rate ? `${stream.frame_rate} fps` : null);
    parts.push(stream.hdr_format ? stream.hdr_format.toUpperCase().replace("_", " ") : null);
  }
  if (stream.kind === "audio") parts.push(stream.channel_layout ?? (stream.channels ? `${stream.channels} ch` : null));
  parts.push(stream.language, stream.title, stream.default ? "default" : null, stream.forced ? "forced" : null);
  return parts.filter(Boolean).join(" · ");
}

function FilePage({ file }: { file: MediaFileDetail }) {
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const admin = user?.role === "admin";
  const rerun = useMutation({
    mutationFn: (step: AnalysisStep) => api.post(`/media_files/${file.id}/rerun`, { step }),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: keys.mediaFiles.detail(file.id) }),
  });

  return (
    <>
      <PageHeader title={file.filename} description={file.path} />
      <div className="grid gap-6 px-4 py-4 sm:px-6 lg:grid-cols-2 lg:px-8 lg:py-6">
        <Card>
          <CardHeader title="File" />
          <CardBody>
            <FactList>
              <Fact label="State" value={<Badge tone={MEDIA_FILE_STATE_TONES[file.state]}>{MEDIA_FILE_STATE_LABELS[file.state]}</Badge>} />
              {file.last_error ? <Fact label="Last error" value={<span className="text-negative">{file.last_error}</span>} /> : null}
              <Fact label="Library" value={file.library.name} />
              <Fact label="Size" value={formatBytes(file.size)} />
              <Fact label="Container" value={file.container ?? "—"} mono />
              <Fact label="Duration" value={file.duration_seconds ? formatClock(file.duration_seconds) : "—"} />
              <Fact label="Fingerprint" value={file.fingerprint ?? "—"} mono />
              <Fact
                label="Keyframes"
                value={file.keyframes.count ? `${file.keyframes.count} from ${file.keyframes.source}` : "Not indexed yet"}
              />
              {file.titles.map((title) => (
                <Fact key={title.id} label="Holds" value={<Link to={title.path} className="text-primary hover:underline">{title.title}</Link>} />
              ))}
            </FactList>
          </CardBody>
        </Card>

        <Card>
          <CardHeader title="Analysis" description="Each step Stream runs on a file, and how it went." />
          <CardBody>
            <ul className="divide-y divide-border">
              {file.analysis.map((run) => (
                <li key={run.step} className="flex items-start justify-between gap-3 py-2 text-sm">
                  <div className="min-w-0">
                    <p className="text-foreground">{ANALYSIS_STEP_LABELS[run.step]}</p>
                    <p className="text-xs text-muted">
                      {run.finished_at ? `Done ${relativeTime(run.finished_at)}${run.duration_ms !== null ? ` in ${run.duration_ms} ms` : ""}` : "Not run yet"}
                      {run.tool_version ? ` · ${run.tool_version}` : ""}
                    </p>
                    {run.error ? <p className="text-xs text-negative">{run.error}</p> : null}
                  </div>
                  <div className="flex shrink-0 items-center gap-1">
                    <Badge tone={ANALYSIS_STATUS_TONES[run.status]}>{ANALYSIS_STATUS_LABELS[run.status]}</Badge>
                    {admin ? (
                      <IconButton label={`Run ${ANALYSIS_STEP_LABELS[run.step]} again`} onClick={() => rerun.mutate(run.step)} disabled={rerun.isPending}>
                        <RefreshCw className="h-4 w-4" aria-hidden />
                      </IconButton>
                    ) : null}
                  </div>
                </li>
              ))}
            </ul>
          </CardBody>
        </Card>

        <Card>
          <CardHeader title="Streams" />
          <CardBody>
            <ul className="space-y-1 text-sm">
              {file.streams.map((stream) => (
                <li key={stream.index} className="flex gap-3">
                  <span className="w-16 shrink-0 text-muted">
                    #{stream.index} {stream.kind}
                  </span>
                  <span className="min-w-0 text-foreground">{describe(stream)}</span>
                </li>
              ))}
            </ul>
            {file.subtitles.some((track) => track.external) ? (
              <>
                <p className="mt-4 text-sm font-medium text-foreground">Subtitle files beside it</p>
                <ul className="mt-1 space-y-1 text-sm text-muted">
                  {file.subtitles.filter((track) => track.external).map((track) => (
                    <li key={track.id}>
                      {track.codec} · {track.language ?? "unknown language"}
                      {track.forced ? " · forced" : ""}
                    </li>
                  ))}
                </ul>
              </>
            ) : null}
          </CardBody>
        </Card>

        <MarkersCard file={file} admin={admin} />

        <Card>
          <CardHeader title="On each device" description="What pressing Play would do on each device seen this month." />
          <CardBody>
            {file.devices.length === 0 ? (
              <p className="text-sm text-muted">No devices yet. Each browser that plays something is remembered here.</p>
            ) : (
              <ul className="space-y-3 text-sm">
                {file.devices.map((row) => (
                  <li key={row.device.id}>
                    <p className="flex items-center gap-2 text-foreground">
                      {row.device.name}
                      <Badge tone={PLAYBACK_METHOD_TONES[row.method]}>{PLAYBACK_METHOD_LABELS[row.method]}</Badge>
                    </p>
                    <p className="text-muted">{row.summary}</p>
                  </li>
                ))}
              </ul>
            )}
          </CardBody>
        </Card>

        <Card>
          <CardHeader title="Optimized version" description="Played instead of converting the video live, wherever the original would need that." />
          <CardBody>
            <OptimizedStatus mediaFileId={file.id} version={file.optimized} admin={admin} />
          </CardBody>
        </Card>
      </div>
    </>
  );
}

const MARKER_LABELS: Record<MarkerKind, string> = { intro: "Intro", recap: "Recap", credits: "Credits" };
const SOURCE_LABELS = { chapter: "from a chapter", detected: "matched across the season", manual: "set by hand" } as const;

/** Intro, recap and credits: where they are, where that came from, and a correction (PROPOSAL §8.2). */
function MarkersCard({ file, admin }: { file: MediaFileDetail; admin: boolean }) {
  return (
    <Card>
      <CardHeader title="Skippable parts" description="What the player offers to skip. A correction here is never overwritten." />
      <CardBody className="space-y-4">
        {MARKER_KINDS.map((kind) => (
          <MarkerRow key={kind} file={file} kind={kind} admin={admin} />
        ))}
      </CardBody>
    </Card>
  );
}

function MarkerRow({ file, kind, admin }: { file: MediaFileDetail; kind: MarkerKind; admin: boolean }) {
  const queryClient = useQueryClient();
  const marker = file.markers.find((candidate) => candidate.kind === kind);
  const [start, setStart] = useState(marker ? String(marker.start) : "");
  const [end, setEnd] = useState(marker ? String(marker.end) : "");
  const refresh = (data: MediaFileDetail) => queryClient.setQueryData(keys.mediaFiles.detail(file.id), data);
  const save = useFormMutation({
    mutationFn: () => api.put<MediaFileDetail>(`/media_files/${file.id}/markers/${kind}`, { start, end }),
    onSuccess: refresh,
    fallback: "Could not save",
  });
  const clear = useMutation({
    mutationFn: () => api.delete<MediaFileDetail>(`/media_files/${file.id}/markers/${kind}`),
    onSuccess: (data) => {
      setStart("");
      setEnd("");
      refresh(data);
    },
  });

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    save.mutate();
  }

  return (
    <div className="space-y-1 text-sm">
      <p className="text-foreground">
        {MARKER_LABELS[kind]}{" "}
        <span className="text-muted">
          {marker
            ? `${formatClock(marker.start)}–${formatClock(marker.end)}, ${SOURCE_LABELS[marker.source]}${marker.source === "detected" ? ` (${Math.round(marker.confidence * 100)}% sure)` : ""}`
            : "none found"}
        </span>
      </p>
      {admin ? (
        <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-2">
          <Input aria-label={`${MARKER_LABELS[kind]} start, seconds`} className="w-24" inputMode="decimal" placeholder="start s" value={start} onChange={(event) => setStart(event.target.value)} />
          <Input aria-label={`${MARKER_LABELS[kind]} end, seconds`} className="w-24" inputMode="decimal" placeholder="end s" value={end} onChange={(event) => setEnd(event.target.value)} />
          <Button type="submit" size="sm" variant="secondary" disabled={save.isPending || !start || !end}>
            Save
          </Button>
          {marker ? (
            <Button type="button" size="sm" variant="ghost" onClick={() => clear.mutate()} disabled={clear.isPending}>
              Clear
            </Button>
          ) : null}
          <FormError message={save.errorMessage} />
        </form>
      ) : null}
    </div>
  );
}
