import { formatClock } from "@/lib/format";
import { useMemo, useState } from "react";
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { api } from "@/api/client";
import type { Column } from "@/lib/dataTable";
import { PLAYBACK_METHOD_LABELS, PLAYBACK_METHOD_TONES, PLAYBACK_OUTCOME_LABELS, PLAYBACK_OUTCOME_TONES } from "@/lib/playback";
import { keys } from "@/lib/queryKeys";
import { toSearch } from "@/lib/tableParams";
import { absoluteTime, relativeTime } from "@/lib/time";
import { useOptimizeActions } from "@/hooks/useOptimizeActions";
import { useTableParams } from "@/hooks/useTableParams";
import { Badge } from "@/components/ui/Badge";
import { BulkActionBar } from "@/components/ui/BulkActionBar";
import { Button } from "@/components/ui/Button";
import { DataTable } from "@/components/ui/DataTable";
import { EmptyState, ErrorState, LoadingState } from "@/components/ui/PageState";
import { Pager } from "@/components/ui/Pager";
import { Select } from "@/components/ui/Select";
import { TableToolbar } from "@/components/ui/TableToolbar";
import { ToggleChips } from "@/components/ui/ToggleChips";
import {
  PLAYBACK_METHODS,
  PLAYBACK_OUTCOMES,
  type Page,
  type PlaybackDecisionDetail,
  type PlaybackDecisionRow,
  type PlaybackFacets,
} from "@/types";

const FILTERS = ["q", "methods", "outcomes", "profile_id", "device_id", "from"] as const;
const ARRAYS = ["methods", "outcomes"] as const;
const DEFAULT_SORT = { key: "started_at", direction: "desc" } as const;
const PER = 50;

/** "When" as the table offers it: how far back from now. */
const SINCE = [
  { value: "", label: "Any time" },
  { value: "1", label: "Last 24 hours" },
  { value: "7", label: "Last 7 days" },
  { value: "30", label: "Last 30 days" },
] as const;

const METHOD_OPTIONS = PLAYBACK_METHODS.map((method) => ({ value: method, label: PLAYBACK_METHOD_LABELS[method] }));
const OUTCOME_OPTIONS = PLAYBACK_OUTCOMES.map((outcome) => ({ value: outcome, label: PLAYBACK_OUTCOME_LABELS[outcome] }));

/** Server-sorted: the value is never read, only its presence makes the header a button. */
const SERVER = () => null;

function sinceValue(from: string | null): string {
  if (!from) return "";
  const days = Math.round((Date.now() - new Date(from).getTime()) / 86_400_000);
  return SINCE.find((option) => option.value === String(days))?.value ?? "";
}

/**
 * Every press of Play: why it went the way it did and how it went, a page
 * at a time, filtered and sorted on the server. Opening a row asks for the
 * rest — the decision's particulars and what the player reported.
 */
export function SessionsTable() {
  const table = useTableParams({ filters: FILTERS, arrays: ARRAYS, defaultSort: DEFAULT_SORT });
  const [selected, setSelected] = useState<string[]>([]);
  const { act } = useOptimizeActions();
  const query = { ...table.query, per: PER };
  const sessions = useQuery({
    queryKey: keys.playbackDecisions.list(query),
    queryFn: ({ signal }) => api.get<Page<PlaybackDecisionRow>>(`/playback_decisions${toSearch(query)}`, { signal }),
    placeholderData: keepPreviousData,
    refetchInterval: 15_000,
  });
  const facets = useQuery({ queryKey: keys.playbackDecisions.facets(), queryFn: ({ signal }) => api.get<PlaybackFacets>("/playback_decisions/facets", { signal }) });

  const rows = sessions.data?.rows ?? [];
  const shown = selected.filter((id) => rows.some((row) => row.id === id));
  const files = [...new Set(rows.filter((row) => shown.includes(row.id) && row.media_file).map((row) => row.media_file!.id))];
  const columns = useMemo(() => sessionColumns(), []);

  return (
    <div className="space-y-4">
      <TableToolbar
        search={table.get("q") ?? ""}
        onSearch={(q) => table.set({ q })}
        searchLabel="Search titles and files"
        active={table.active}
        onClear={table.clear}
        summary={sessions.data ? `${sessions.data.total.toLocaleString()}${sessions.data.total_capped ? "+" : ""} play${sessions.data.total === 1 ? "" : "s"}` : null}
      >
        <Select aria-label="When" value={sinceValue(table.get("from"))} onChange={(event) => table.set({ from: event.target.value ? new Date(Date.now() - Number(event.target.value) * 86_400_000).toISOString() : null })} className="w-40">
          {SINCE.map((option) => (
            <option key={option.value} value={option.value}>
              {option.label}
            </option>
          ))}
        </Select>
        <Select aria-label="Profile" value={table.get("profile_id") ?? ""} onChange={(event) => table.set({ profile_id: event.target.value })} className="w-40">
          <option value="">Every profile</option>
          {facets.data?.profiles.map((profile) => (
            <option key={profile.id} value={profile.id}>
              {profile.name}
            </option>
          ))}
        </Select>
        <Select aria-label="Device" value={table.get("device_id") ?? ""} onChange={(event) => table.set({ device_id: event.target.value })} className="w-48">
          <option value="">Every device</option>
          {facets.data?.devices.map((device) => (
            <option key={device.id} value={device.id}>
              {device.name}
            </option>
          ))}
        </Select>
      </TableToolbar>
      <div className="flex flex-wrap gap-x-6 gap-y-2">
        <ToggleChips label="How it went" options={OUTCOME_OPTIONS} selected={table.getAll("outcomes")} onChange={(outcomes) => table.set({ outcomes })} />
        <ToggleChips label="How it played" options={METHOD_OPTIONS} selected={table.getAll("methods")} onChange={(methods) => table.set({ methods })} />
      </div>

      <BulkActionBar count={shown.length} noun={shown.length === 1 ? "play selected" : "plays selected"} onClear={() => setSelected([])}>
        <Button size="sm" variant="secondary" disabled={files.length === 0 || act.isPending} onClick={() => act.mutate({ action: "optimize", ids: files })}>
          Optimize their files tonight
        </Button>
        <Button size="sm" variant="secondary" disabled={files.length === 0 || act.isPending} onClick={() => act.mutate({ action: "optimize", ids: files, now: true })}>
          Optimize now
        </Button>
      </BulkActionBar>

      {sessions.isPending ? (
        <LoadingState label="Loading plays…" />
      ) : sessions.isError ? (
        <ErrorState message="Could not load plays." onRetry={() => void sessions.refetch()} />
      ) : rows.length === 0 ? (
        table.active > 0 ? (
          <EmptyState title="No plays match" description="Try fewer filters." />
        ) : (
          <EmptyState title="Nothing played yet" description="Every press of Play shows up here with the reason behind it." />
        )
      ) : (
        <div className="rounded-[var(--radius-card)] border border-border">
          <DataTable
            caption="Plays, newest first unless sorted otherwise"
            columns={columns}
            rows={rows}
            rowKey={(row) => row.id}
            sort={table.sort}
            onSortChange={table.setSort}
            presorted
            selection={{ selected: shown, onChange: setSelected, rowLabel: (row) => `Select ${row.title ?? "this play"}` }}
            rowClassName={(row) => (row.outcome === "failed" || row.outcome === "errored" ? "bg-negative/5" : undefined)}
            detail={(row) => <SessionDetail id={row.id} />}
            card={(row) => <SessionCard row={row} />}
            cardBelow="lg"
          />
        </div>
      )}
      {sessions.data ? (
        <Pager page={table.page - 1} per={PER} total={sessions.data.total} onChange={(page) => table.setPage(page + 1)} noun="plays" />
      ) : null}
    </div>
  );
}

function sessionColumns(): Column<PlaybackDecisionRow>[] {
  return [
    {
      key: "started_at",
      header: "Started",
      sortValue: SERVER,
      className: "whitespace-nowrap",
      cell: (row) => <span title={absoluteTime(row.started_at)}>{relativeTime(row.started_at)}</span>,
    },
    {
      key: "title",
      header: "Title",
      sortValue: SERVER,
      cell: (row) => (
        <div className="min-w-0">
          <p className="font-medium text-foreground">{row.title ?? row.media_file?.filename ?? "Unknown"}</p>
          {row.summary ? <p className="text-xs text-muted">{row.summary}</p> : null}
        </div>
      ),
    },
    { key: "profile", header: "Profile", sortValue: SERVER, cell: (row) => row.profile?.name ?? "—" },
    { key: "device", header: "Device", sortValue: SERVER, cell: (row) => row.device.name ?? "—" },
    {
      key: "method",
      header: "Played as",
      sortValue: SERVER,
      cell: (row) => <Badge tone={PLAYBACK_METHOD_TONES[row.method]}>{PLAYBACK_METHOD_LABELS[row.method]}</Badge>,
    },
    {
      key: "startup_ms",
      header: "Start-up",
      sortValue: SERVER,
      className: "text-right tabular-nums",
      cell: (row) => (row.startup_ms === null ? "—" : `${row.startup_ms} ms`),
    },
    { key: "stalls", header: "Stalls", sortValue: SERVER, className: "text-right tabular-nums", cell: (row) => row.stalls || "—" },
    { key: "errors", header: "Errors", sortValue: SERVER, className: "text-right tabular-nums", cell: (row) => row.errors || "—" },
    {
      key: "outcome",
      header: "Outcome",
      sortValue: SERVER,
      cell: (row) => <Badge tone={PLAYBACK_OUTCOME_TONES[row.outcome]}>{PLAYBACK_OUTCOME_LABELS[row.outcome]}</Badge>,
    },
  ];
}

function SessionCard({ row }: { row: PlaybackDecisionRow }) {
  return (
    <div className="space-y-1 text-sm">
      <div className="flex flex-wrap items-center gap-2">
        <Badge tone={PLAYBACK_OUTCOME_TONES[row.outcome]}>{PLAYBACK_OUTCOME_LABELS[row.outcome]}</Badge>
        <Badge tone={PLAYBACK_METHOD_TONES[row.method]}>{PLAYBACK_METHOD_LABELS[row.method]}</Badge>
        <span className="font-medium text-foreground">{row.title ?? row.media_file?.filename ?? "Unknown"}</span>
      </div>
      <p className="text-muted">
        {[row.profile?.name, row.device.name, relativeTime(row.started_at), row.startup_ms === null ? null : `${row.startup_ms} ms to start`]
          .filter(Boolean)
          .join(" · ")}
      </p>
      {row.summary ? <p className="text-foreground">{row.summary}</p> : null}
      {row.transcode_error ? <p className="text-negative">{row.transcode_error}</p> : null}
    </div>
  );
}

/** The rest of one play, asked for when its row opens. */
function SessionDetail({ id }: { id: string }) {
  const detail = useQuery({
    queryKey: keys.playbackDecisions.detail(id),
    queryFn: ({ signal }) => api.get<PlaybackDecisionDetail>(`/playback_decisions/${id}`, { signal }),
  });
  const { act } = useOptimizeActions();

  if (detail.isPending) return <LoadingState label="Loading the play…" />;
  if (detail.isError) return <ErrorState message="Could not load this play." onRetry={() => void detail.refetch()} />;
  const row = detail.data;
  const particulars = Object.entries(row.decision).filter(([, value]) => value !== null && value !== undefined);

  return (
    <div className="grid gap-6 text-sm lg:grid-cols-2">
      <div className="space-y-2">
        <p className="font-medium text-foreground">Why</p>
        {row.summary ? <p className="text-foreground">{row.summary}</p> : null}
        {row.reasons.slice(1).map((reason) => (
          <p key={reason} className="text-muted">
            Also: {reason}
          </p>
        ))}
        {row.transcode_error ? <p className="text-negative">{row.transcode_error}</p> : null}
        {row.fix_hint ? <p className="text-muted">{row.fix_hint}</p> : null}
        {particulars.length > 0 ? (
          <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-xs text-muted">
            {particulars.map(([key, value]) => (
              <div key={key} className="contents">
                <dt className="capitalize text-foreground">{key}</dt>
                <dd className="break-all font-mono">{typeof value === "string" ? value : JSON.stringify(value)}</dd>
              </div>
            ))}
          </dl>
        ) : null}
        <div className="flex flex-wrap gap-2 pt-1">
          {row.media_file ? (
            <>
              <Link to={`/files/${row.media_file.id}`} className="inline-flex h-8 items-center text-sm text-primary hover:underline">
                File details
              </Link>
              {row.method === "video_transcode" ? (
                <>
                  <Button size="sm" variant="secondary" disabled={act.isPending} onClick={() => act.mutate({ action: "optimize", ids: [row.media_file!.id] })}>
                    Optimize this file tonight
                  </Button>
                  <Button size="sm" variant="secondary" disabled={act.isPending} onClick={() => act.mutate({ action: "optimize", ids: [row.media_file!.id], now: true })}>
                    Optimize now
                  </Button>
                </>
              ) : null}
            </>
          ) : null}
        </div>
      </div>
      <div className="space-y-2">
        <p className="font-medium text-foreground">What the player reported</p>
        {row.events.length === 0 ? (
          <p className="text-muted">Nothing.</p>
        ) : (
          <ol className="space-y-1 text-xs">
            {row.events.map((event, index) => (
              <li key={`${event.at}-${index}`} className="flex gap-3">
                <span className="w-20 shrink-0 tabular-nums text-muted" title={absoluteTime(event.at)}>
                  {event.position_seconds === null ? "" : `at ${formatClock(event.position_seconds)}`}
                </span>
                <span className={event.kind === "error" ? "font-medium text-negative" : event.kind === "stall" ? "font-medium text-warning" : "text-foreground"}>
                  {event.kind}
                </span>
                {event.message ? <span className="min-w-0 break-words text-muted">{event.message}</span> : null}
              </li>
            ))}
          </ol>
        )}
      </div>
    </div>
  );
}
