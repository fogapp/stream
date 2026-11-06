import { useMemo, type ReactNode } from "react";
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { AlertTriangle } from "lucide-react";
import { api } from "@/api/client";
import { formatBytes } from "@/lib/bytes";
import type { Column } from "@/lib/dataTable";
import { OPTIMIZED_REASON_LABELS, OPTIMIZED_STATE_LABELS, OPTIMIZED_STATE_TONES, formatDuration } from "@/lib/optimized";
import { keys } from "@/lib/queryKeys";
import { toSearch, type ApiQuery } from "@/lib/tableParams";
import { absoluteTime, relativeTime, untilTime } from "@/lib/time";
import { useOptimizeActions } from "@/hooks/useOptimizeActions";
import { useTableParams, type TableParams } from "@/hooks/useTableParams";
import { Badge } from "@/components/ui/Badge";
import { BulkActionBar } from "@/components/ui/BulkActionBar";
import { Button } from "@/components/ui/Button";
import { Checkbox } from "@/components/ui/Checkbox";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { DataTable } from "@/components/ui/DataTable";
import { EmptyState, ErrorState, LoadingState } from "@/components/ui/PageState";
import { Pager } from "@/components/ui/Pager";
import { ProgressBar } from "@/components/ui/ProgressBar";
import { Select } from "@/components/ui/Select";
import { TableToolbar } from "@/components/ui/TableToolbar";
import { ToggleChips } from "@/components/ui/ToggleChips";
import { OptimizedStatus } from "./OptimizedStatus";
import { OPTIMIZED_REASONS, type OptimizeAction, type OptimizedVersionTableRow, type Page } from "@/types";
import { useBulkSelection } from "@/hooks/useBulkSelection";
import { plural } from "@/lib/format";

const PER = 50;
const SERVER = () => null;
const REASON_OPTIONS = OPTIMIZED_REASONS.map((reason) => ({ value: reason, label: OPTIMIZED_REASON_LABELS[reason] }));

const QUEUE_FILTERS = ["q", "reasons", "interrupted"] as const;
const QUEUE_ARRAYS = ["reasons"] as const;
const QUEUE_SORT = { key: "queue", direction: "asc" } as const;
const QUEUE_STATES = ["encoding", "queued"] as const;

const DONE_FILTERS = ["q", "states", "reasons", "unplayed_days"] as const;
const DONE_ARRAYS = ["states", "reasons"] as const;
const DONE_SORT = { key: "finished_at", direction: "desc" } as const;
const DONE_STATES = ["ready", "failed", "skipped"] as const;
const DONE_STATE_OPTIONS = DONE_STATES.map((state) => ({ value: state, label: OPTIMIZED_STATE_LABELS[state] }));

/** The rows of one versions table, the ones ticked on this page, and the bulk-action runner. */
function useVersions(table: TableParams, scope: ApiQuery, encoding: boolean) {
  const { act } = useOptimizeActions();
  const query = { ...scope, ...table.query, per: PER };
  const versions = useQuery({
    queryKey: keys.optimizedVersions.list(query),
    queryFn: ({ signal }) => api.get<Page<OptimizedVersionTableRow>>(`/optimized_versions${toSearch(query)}`, { signal }),
    placeholderData: keepPreviousData,
    refetchInterval: (state) => (encoding || state.state.data?.rows.some((row) => row.state === "encoding") ? 5_000 : 30_000),
  });
  const rows = versions.data?.rows ?? [];
  const { shown, setSelected } = useBulkSelection(rows);
  const run = (action: OptimizeAction, now = false) =>
    act.mutate({ action, ids: shown, now }, { onSuccess: () => setSelected([]) });
  return { versions, rows, shown, setSelected, run, busy: act.isPending };
}

/**
 * What's scheduled: encoding first, then the queue in the order the
 * transcoder will take it — each numbered in that line, with why it's
 * there, when it's wanted, and whether the budget will have room.
 */
export function QueueTable({ encoding }: { encoding: boolean }) {
  const table = useTableParams({ filters: QUEUE_FILTERS, arrays: QUEUE_ARRAYS, defaultSort: QUEUE_SORT });
  const { versions, rows, shown, setSelected, run, busy } = useVersions(table, { states: QUEUE_STATES }, encoding);
  const columns = useMemo(() => queueColumns(), []);

  return (
    <VersionsLayout
      table={table}
      versions={versions}
      noun="waiting"
      emptyTitle="Nothing is waiting"
      emptyDescription="Optimize a file from Needs converting, or let the hourly pass queue the ones no device plays without converting."
      filters={
        <Checkbox
          label="Stopped part way"
          checked={table.get("interrupted") === "true"}
          onChange={(checked) => table.set({ interrupted: checked ? "true" : null })}
        />
      }
      chips={<ToggleChips label="Why it's queued" options={REASON_OPTIONS} selected={table.getAll("reasons")} onChange={(reasons) => table.set({ reasons })} />}
      actions={
        <>
          <Button size="sm" variant="secondary" disabled={busy} onClick={() => run("prioritize")}>
            Do next
          </Button>
          <Button size="sm" variant="secondary" disabled={busy} onClick={() => run("optimize", true)}>
            Start now
          </Button>
          <ConfirmButton size="sm" variant="ghost" disabled={busy} onConfirm={() => run("skip")} question="Never make these?">
            Don&apos;t optimize
          </ConfirmButton>
          <ConfirmButton size="sm" variant="ghost" disabled={busy} onConfirm={() => run("delete")} question="Delete? They may be queued again.">
            Delete
          </ConfirmButton>
        </>
      }
      rows={rows}
      shown={shown}
      setSelected={setSelected}
      columns={columns}
      caption="Optimized versions waiting, in the order they'll be made"
    />
  );
}

/**
 * What's been done: versions made, failed, or that an admin said not to
 * make — with how long each took, how much it has played since, and when
 * its file was last played, for deciding what's worth the space.
 */
export function OptimizedTable() {
  const table = useTableParams({ filters: DONE_FILTERS, arrays: DONE_ARRAYS, defaultSort: DONE_SORT });
  const states = table.getAll("states");
  const { versions, rows, shown, setSelected, run, busy } = useVersions(table, states.length > 0 ? {} : { states: DONE_STATES }, false);
  const columns = useMemo(() => doneColumns(), []);

  return (
    <VersionsLayout
      table={table}
      versions={versions}
      noun="versions"
      emptyTitle="None yet"
      emptyDescription="Versions show up here once they're made, or if one fails."
      filters={
        <Select
          aria-label="Last played"
          value={table.get("unplayed_days") ?? ""}
          onChange={(event) => table.set({ unplayed_days: event.target.value })}
          className="w-52"
        >
          <option value="">Played any time</option>
          <option value="30">Not played in 30 days</option>
          <option value="90">Not played in 90 days</option>
          <option value="365">Not played in a year</option>
        </Select>
      }
      chips={
        <>
          <ToggleChips label="State" options={DONE_STATE_OPTIONS} selected={states} onChange={(next) => table.set({ states: next })} />
          <ToggleChips label="Why it was made" options={REASON_OPTIONS} selected={table.getAll("reasons")} onChange={(reasons) => table.set({ reasons })} />
        </>
      }
      actions={
        <>
          <Button size="sm" variant="secondary" disabled={busy} onClick={() => run("retry")}>
            Retry
          </Button>
          <Button size="sm" variant="secondary" disabled={busy} onClick={() => run("reencode")}>
            Make again
          </Button>
          <Button size="sm" variant="secondary" disabled={busy} onClick={() => run("unskip")}>
            Allow again
          </Button>
          <ConfirmButton size="sm" variant="ghost" disabled={busy} onConfirm={() => run("skip")} question="Delete them and never make them again?">
            Don&apos;t optimize
          </ConfirmButton>
          <ConfirmButton size="sm" variant="ghost" disabled={busy} onConfirm={() => run("delete")} question="Delete? They may be made again.">
            Delete
          </ConfirmButton>
        </>
      }
      rows={rows}
      shown={shown}
      setSelected={setSelected}
      columns={columns}
      caption="Optimized versions made, failed or not wanted"
    />
  );
}

function VersionsLayout({
  table,
  versions,
  noun,
  emptyTitle,
  emptyDescription,
  filters,
  chips,
  actions,
  rows,
  shown,
  setSelected,
  columns,
  caption,
}: {
  table: TableParams;
  versions: ReturnType<typeof useVersions>["versions"];
  noun: string;
  emptyTitle: string;
  emptyDescription: string;
  filters: ReactNode;
  chips: ReactNode;
  actions: ReactNode;
  rows: OptimizedVersionTableRow[];
  shown: string[];
  setSelected: (ids: string[]) => void;
  columns: Column<OptimizedVersionTableRow>[];
  caption: string;
}) {
  return (
    <div className="space-y-4">
      <TableToolbar
        search={table.get("q") ?? ""}
        onSearch={(q) => table.set({ q })}
        searchLabel="Search titles and files"
        active={table.active}
        onClear={table.clear}
        summary={versions.data ? `${versions.data.total.toLocaleString()} ${versions.data.total === 1 ? noun.replace(/s$/, "") : noun}` : null}
      >
        {filters}
      </TableToolbar>
      <div className="flex flex-wrap gap-x-6 gap-y-2">{chips}</div>
      <BulkActionBar count={shown.length} noun={shown.length === 1 ? "file selected" : "files selected"} onClear={() => setSelected([])}>
        {actions}
      </BulkActionBar>
      {versions.isPending ? (
        <LoadingState label="Loading optimized versions…" />
      ) : versions.isError ? (
        <ErrorState message="Could not load optimized versions." onRetry={() => void versions.refetch()} />
      ) : rows.length === 0 ? (
        table.active > 0 ? (
          <EmptyState title="Nothing matches" description="Try fewer filters." />
        ) : (
          <EmptyState title={emptyTitle} description={emptyDescription} />
        )
      ) : (
        <div className="rounded-[var(--radius-card)] border border-border">
          <DataTable
            caption={caption}
            columns={columns}
            rows={rows}
            rowKey={(row) => row.media_file_id}
            sort={table.sort}
            onSortChange={table.setSort}
            presorted
            selection={{ selected: shown, onChange: setSelected, rowLabel: (row) => `Select ${row.title ?? row.filename ?? "this file"}` }}
            detail={(row) => <OptimizedStatus mediaFileId={row.media_file_id} version={row} admin />}
            card={(row) => <VersionCard row={row} />}
            cardBelow="lg"
          />
        </div>
      )}
      {versions.data ? (
        <Pager page={table.page - 1} per={PER} total={versions.data.total} onChange={(page) => table.setPage(page + 1)} noun={noun} />
      ) : null}
    </div>
  );
}

function titleCell(row: OptimizedVersionTableRow) {
  return (
    <div className="min-w-0">
      <Link to={`/files/${row.media_file_id}`} className="font-medium text-foreground hover:underline">
        {row.title ?? row.filename ?? "Unknown file"}
      </Link>
      {row.error ? <p className="text-xs text-negative">{row.error}</p> : null}
      {row.interruption && row.state !== "ready" ? (
        <p className="text-xs text-muted">
          Stopped {row.interruptions === 1 ? "once" : `${row.interruptions}×`}: {row.interruption}
        </p>
      ) : null}
    </div>
  );
}

function reasonCell(row: OptimizedVersionTableRow) {
  return row.reason ? OPTIMIZED_REASON_LABELS[row.reason] : row.origin === "manual" ? "Asked for" : "—";
}

function queueColumns(): Column<OptimizedVersionTableRow>[] {
  return [
    {
      key: "queue",
      header: "#",
      sortValue: SERVER,
      className: "w-12 tabular-nums text-muted",
      cell: (row) => (row.state === "encoding" ? "▶" : row.queue_position ?? "—"),
    },
    { key: "title", header: "Title", sortValue: SERVER, cell: titleCell },
    {
      key: "reason",
      header: "Why",
      cell: (row) => (
        <span>
          {reasonCell(row)}
          {row.prioritized_at ? <span className="text-xs text-primary"> · next</span> : null}
          {row.run_now ? <span className="text-xs text-primary"> · now</span> : null}
        </span>
      ),
    },
    {
      key: "needed_at",
      header: "Wanted",
      sortValue: SERVER,
      className: "whitespace-nowrap",
      cell: (row) => (row.needed_at ? <span title={absoluteTime(row.needed_at)}>{untilTime(row.needed_at)}</span> : "—"),
    },
    {
      key: "size",
      header: "Size (about)",
      className: "text-right tabular-nums whitespace-nowrap",
      cell: (row) =>
        row.estimated_bytes === null ? (
          "—"
        ) : (
          <span className={row.fits_budget === false ? "inline-flex items-center gap-1 text-warning" : undefined} title={row.fits_budget === false ? "Past what the budget has room for: it waits until there's space" : undefined}>
            {row.fits_budget === false ? <AlertTriangle className="h-3.5 w-3.5" aria-label="Won't fit in the budget" /> : null}
            {formatBytes(row.estimated_bytes)}
          </span>
        ),
    },
    {
      key: "progress",
      header: "Progress",
      sortValue: SERVER,
      className: "w-40",
      cell: (row) =>
        row.state === "encoding" ? (
          <div className="space-y-1">
            <ProgressBar value={row.progress} label={`Encoding ${row.title ?? row.filename ?? "file"}`} />
            <p className="text-xs tabular-nums text-muted">{Math.round(row.progress * 100)}%{row.worker ? ` on ${row.worker}` : ""}</p>
          </div>
        ) : (
          <Badge tone={OPTIMIZED_STATE_TONES[row.state]}>{OPTIMIZED_STATE_LABELS[row.state]}</Badge>
        ),
    },
  ];
}

function doneColumns(): Column<OptimizedVersionTableRow>[] {
  return [
    {
      key: "finished_at",
      header: "Finished",
      sortValue: SERVER,
      className: "whitespace-nowrap",
      cell: (row) => (row.finished_at ? <span title={absoluteTime(row.finished_at)}>{relativeTime(row.finished_at)}</span> : "—"),
    },
    { key: "title", header: "Title", sortValue: SERVER, cell: titleCell },
    { key: "reason", header: "Why", cell: reasonCell },
    { key: "size", header: "Size", sortValue: SERVER, className: "text-right tabular-nums whitespace-nowrap", cell: (row) => (row.size ? formatBytes(row.size) : "—") },
    {
      key: "encode_seconds",
      header: "Took",
      sortValue: SERVER,
      className: "text-right tabular-nums whitespace-nowrap",
      cell: (row) => (row.encode_seconds ? formatDuration(row.encode_seconds) : "—"),
    },
    { key: "plays", header: "Plays since", sortValue: SERVER, className: "text-right tabular-nums", cell: (row) => (row.state === "ready" ? row.plays_since : "—") },
    {
      key: "last_played_at",
      header: "Last played",
      sortValue: SERVER,
      className: "whitespace-nowrap",
      cell: (row) => (row.last_played_at ? <span title={absoluteTime(row.last_played_at)}>{relativeTime(row.last_played_at)}</span> : "never"),
    },
    {
      key: "state",
      header: "State",
      cell: (row) => (
        <span className="inline-flex flex-wrap items-center gap-1">
          <Badge tone={OPTIMIZED_STATE_TONES[row.state]}>{OPTIMIZED_STATE_LABELS[row.state]}</Badge>
          {row.height ? <span className="text-xs text-muted">{row.height}p</span> : null}
        </span>
      ),
    },
  ];
}

function VersionCard({ row }: { row: OptimizedVersionTableRow }) {
  return (
    <div className="space-y-1 text-sm">
      <div className="flex flex-wrap items-center gap-2">
        <Badge tone={OPTIMIZED_STATE_TONES[row.state]}>{OPTIMIZED_STATE_LABELS[row.state]}</Badge>
        {row.queue_position ? <span className="tabular-nums text-muted">#{row.queue_position}</span> : null}
        <Link to={`/files/${row.media_file_id}`} className="font-medium text-foreground hover:underline">
          {row.title ?? row.filename ?? "Unknown file"}
        </Link>
      </div>
      {row.state === "encoding" ? <ProgressBar value={row.progress} label={`Encoding ${row.title ?? "file"}`} /> : null}
      <p className="text-muted">
        {[
          reasonCell(row),
          row.size ? formatBytes(row.size) : row.estimated_bytes ? `about ${formatBytes(row.estimated_bytes)}` : null,
          row.state === "ready" ? `${plural(row.plays_since, "play")} since` : null,
        ]
          .filter(Boolean)
          .join(" · ")}
      </p>
      {row.error ? <p className="text-negative">{row.error}</p> : null}
    </div>
  );
}
