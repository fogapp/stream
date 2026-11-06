import { useMemo } from "react";
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { api } from "@/api/client";
import { formatBytes } from "@/lib/bytes";
import type { Column } from "@/lib/dataTable";
import { CONVERSION_STATUS_LABELS, CONVERSION_STATUS_TONES } from "@/lib/optimized";
import { keys } from "@/lib/queryKeys";
import { toSearch } from "@/lib/tableParams";
import { absoluteTime, relativeTime } from "@/lib/time";
import { useOptimizeActions } from "@/hooks/useOptimizeActions";
import { useTableParams } from "@/hooks/useTableParams";
import { Badge } from "@/components/ui/Badge";
import { BulkActionBar } from "@/components/ui/BulkActionBar";
import { Button } from "@/components/ui/Button";
import { Checkbox } from "@/components/ui/Checkbox";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { DataTable } from "@/components/ui/DataTable";
import { EmptyState, ErrorState, LoadingState } from "@/components/ui/PageState";
import { Pager } from "@/components/ui/Pager";
import { Select } from "@/components/ui/Select";
import { TableToolbar } from "@/components/ui/TableToolbar";
import { ToggleChips } from "@/components/ui/ToggleChips";
import { OptimizedStatus } from "./OptimizedStatus";
import { CONVERSION_STATUSES, type TranscodeReportPage, type TranscodeReportRow } from "@/types";
import { useBulkSelection } from "@/hooks/useBulkSelection";

const FILTERS = ["q", "statuses", "device", "library_id", "all_devices"] as const;
const ARRAYS = ["statuses"] as const;
const DEFAULT_SORT = { key: "conversions", direction: "desc" } as const;
const PER = 50;
const SERVER = () => null;
const STATUS_OPTIONS = CONVERSION_STATUSES.map((status) => ({ value: status, label: CONVERSION_STATUS_LABELS[status] }));

/**
 * What still needs doing: the files some device seen this month would have
 * to convert, the ones converted most for someone first, with where each
 * stands on being optimized and the levers to change it — one file or many.
 */
export function ConvertingTable() {
  const table = useTableParams({ filters: FILTERS, arrays: ARRAYS, defaultSort: DEFAULT_SORT });
  const { act } = useOptimizeActions();
  const query = { ...table.query, per: PER };
  const report = useQuery({
    queryKey: keys.playbackDecisions.report(query),
    queryFn: ({ signal }) => api.get<TranscodeReportPage>(`/playback_decisions/transcode_report${toSearch(query)}`, { signal }),
    placeholderData: keepPreviousData,
    refetchInterval: (state) => (state.state.data?.rows.some((row) => row.status === "encoding") ? 10_000 : false),
  });
  const rows = report.data?.rows ?? [];
  const { shown, setSelected } = useBulkSelection(rows);
  const columns = useMemo(() => conversionColumns(), []);
  const run = (action: "optimize" | "skip", now = false) => act.mutate({ action, ids: shown, now }, { onSuccess: () => setSelected([]) });

  return (
    <div className="space-y-4">
      <TableToolbar
        search={table.get("q") ?? ""}
        onSearch={(q) => table.set({ q })}
        searchLabel="Search titles and files"
        active={table.active}
        onClear={table.clear}
        summary={report.data ? `${report.data.total.toLocaleString()} file${report.data.total === 1 ? "" : "s"}` : null}
      >
        <Select aria-label="Device" value={table.get("device") ?? ""} onChange={(event) => table.set({ device: event.target.value })} className="w-48">
          <option value="">Any device</option>
          {report.data?.facets.devices.map((device) => (
            <option key={device} value={device}>
              {device}
            </option>
          ))}
        </Select>
        <Select aria-label="Library" value={table.get("library_id") ?? ""} onChange={(event) => table.set({ library_id: event.target.value })} className="w-40">
          <option value="">Every library</option>
          {report.data?.facets.libraries.map((library) => (
            <option key={library.id} value={library.id}>
              {library.name}
            </option>
          ))}
        </Select>
        <Checkbox
          label="No device plays it"
          checked={table.get("all_devices") === "true"}
          onChange={(checked) => table.set({ all_devices: checked ? "true" : null })}
        />
      </TableToolbar>
      <ToggleChips label="Optimized" options={STATUS_OPTIONS} selected={table.getAll("statuses")} onChange={(statuses) => table.set({ statuses })} />

      <BulkActionBar count={shown.length} noun={shown.length === 1 ? "file selected" : "files selected"} onClear={() => setSelected([])}>
        <Button size="sm" variant="secondary" disabled={act.isPending} onClick={() => run("optimize")}>
          Optimize tonight
        </Button>
        <Button size="sm" variant="secondary" disabled={act.isPending} onClick={() => run("optimize", true)}>
          Optimize now
        </Button>
        <ConfirmButton size="sm" variant="ghost" disabled={act.isPending} onConfirm={() => run("skip")} question="Never optimize these?">
          Don&apos;t optimize
        </ConfirmButton>
      </BulkActionBar>

      {report.isPending ? (
        <LoadingState label="Working out what needs converting…" />
      ) : report.isError ? (
        <ErrorState message="Could not build the report." onRetry={() => void report.refetch()} />
      ) : rows.length === 0 ? (
        table.active > 0 ? (
          <EmptyState title="No files match" description="Try fewer filters." />
        ) : (
          <EmptyState title="Nothing needs converting" description="Every device seen this month plays every file without converting its video." />
        )
      ) : (
        <div className="rounded-[var(--radius-card)] border border-border">
          <DataTable
            caption="Files a recent device would convert"
            columns={columns}
            rows={rows}
            rowKey={(row) => row.media_file_id}
            sort={table.sort}
            onSortChange={table.setSort}
            presorted
            selection={{ selected: shown, onChange: setSelected, rowLabel: (row) => `Select ${row.title ?? row.filename}` }}
            detail={(row) => <ConversionDetail row={row} />}
            card={(row) => <ConversionCard row={row} />}
            cardBelow="lg"
          />
        </div>
      )}
      {report.data ? (
        <Pager page={table.page - 1} per={PER} total={report.data.total} onChange={(page) => table.setPage(page + 1)} noun="files" />
      ) : null}
    </div>
  );
}

function conversionColumns(): Column<TranscodeReportRow>[] {
  return [
    {
      key: "title",
      header: "Title",
      sortValue: SERVER,
      cell: (row) => (
        <div className="min-w-0">
          <Link to={`/files/${row.media_file_id}`} className="font-medium text-foreground hover:underline">
            {row.title ?? row.filename}
          </Link>
          <p className="text-xs text-muted">{row.library?.name}</p>
        </div>
      ),
    },
    {
      key: "devices",
      header: "Devices",
      sortValue: SERVER,
      cell: (row) => (
        <span title={row.devices.map((device) => device.device).join(", ")}>
          {row.all_devices ? "Every device" : row.devices.map((device) => device.device).join(", ")}
        </span>
      ),
    },
    {
      key: "conversions",
      header: "Converted (30 days)",
      sortValue: SERVER,
      className: "text-right tabular-nums",
      cell: (row) => row.conversions || "—",
    },
    {
      key: "last_converted_at",
      header: "Last converted",
      sortValue: SERVER,
      className: "whitespace-nowrap",
      cell: (row) => (row.last_converted_at ? <span title={absoluteTime(row.last_converted_at)}>{relativeTime(row.last_converted_at)}</span> : "—"),
    },
    { key: "size", header: "Size", sortValue: SERVER, className: "text-right tabular-nums whitespace-nowrap", cell: (row) => formatBytes(row.size) },
    {
      key: "status",
      header: "Optimized",
      sortValue: SERVER,
      cell: (row) => <Badge tone={CONVERSION_STATUS_TONES[row.status]}>{CONVERSION_STATUS_LABELS[row.status]}</Badge>,
    },
  ];
}

function ConversionCard({ row }: { row: TranscodeReportRow }) {
  return (
    <div className="space-y-1 text-sm">
      <div className="flex flex-wrap items-center gap-2">
        <Badge tone={CONVERSION_STATUS_TONES[row.status]}>{CONVERSION_STATUS_LABELS[row.status]}</Badge>
        <Link to={`/files/${row.media_file_id}`} className="font-medium text-foreground hover:underline">
          {row.title ?? row.filename}
        </Link>
      </div>
      <p className="text-muted">
        {[
          row.conversions ? `converted ${row.conversions}× this month` : "not converted this month",
          row.all_devices ? "every device" : row.devices.map((device) => device.device).join(", "),
          formatBytes(row.size),
        ].join(" · ")}
      </p>
    </div>
  );
}

function ConversionDetail({ row }: { row: TranscodeReportRow }) {
  return (
    <div className="grid gap-6 text-sm lg:grid-cols-2">
      <div className="space-y-1">
        <p className="font-medium text-foreground">Why each device converts it</p>
        {row.devices.map((device) => (
          <p key={device.device} className="text-muted">
            <span className="text-foreground">{device.device}:</span> {device.summary}
          </p>
        ))}
      </div>
      <div className="space-y-1">
        <p className="font-medium text-foreground">Optimized version</p>
        <OptimizedStatus mediaFileId={row.media_file_id} version={row.optimized} admin />
      </div>
    </div>
  );
}
