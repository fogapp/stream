import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Link } from "react-router-dom";
import { api } from "@/api/client";
import type { Column, SortState } from "@/lib/dataTable";
import { FAILURE_CLASS_LABELS } from "@/lib/playback";
import { keys } from "@/lib/queryKeys";
import { absoluteTime, relativeTime } from "@/lib/time";
import { Badge } from "@/components/ui/Badge";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { DataTable } from "@/components/ui/DataTable";
import { EmptyState, ErrorState, LoadingState } from "@/components/ui/PageState";
import { Pager } from "@/components/ui/Pager";
import type { Page, PlaybackLessonRow } from "@/types";

const PER = 50;

/**
 * What plays have taught: each rung that
 * failed for a file on a kind of client, which new plays there skip until
 * it's tried again — and Forget, to try it now.
 */
export function LearnedTable() {
  const [page, setPage] = useState(1);
  // Most recent failure first, as the server orders them.
  const [sort, setSort] = useState<SortState>({ key: "when", direction: "desc" });
  const queryClient = useQueryClient();
  const query = { page, per: PER };
  const lessons = useQuery({
    queryKey: keys.playbackDecisions.lessons(query),
    queryFn: ({ signal }) => api.get<Page<PlaybackLessonRow>>(`/playback_lessons?page=${page}&per=${PER}`, { signal }),
    placeholderData: keepPreviousData,
  });
  const forget = useMutation({
    mutationFn: (id: string) => api.delete(`/playback_lessons/${id}`),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: keys.playbackDecisions.all }),
  });

  if (lessons.isPending) return <LoadingState label="Loading what plays have taught…" />;
  if (lessons.isError) return <ErrorState title="Couldn't load what plays have taught" onRetry={() => void lessons.refetch()} />;
  const rows = lessons.data.rows;
  if (rows.length === 0) {
    return (
      <EmptyState
        title="Nothing learned yet"
        description="When a file fails to play one way on a kind of device, it's tried another way at once — and the way that failed is skipped there next time."
      />
    );
  }

  const columns: Column<PlaybackLessonRow>[] = [
    {
      key: "file",
      header: "File",
      cell: (row) => (
        <Link to={`/files/${row.media_file_id}`} className="font-medium hover:underline">
          {row.filename ?? "A file"}
        </Link>
      ),
    },
    { key: "client", header: "On", cell: (row) => row.client_class },
    { key: "rung", header: "Way it failed", cell: (row) => row.rung_label },
    {
      key: "why",
      header: "Why",
      cell: (row) => (
        <span className="text-muted" title={row.cause ?? undefined}>
          {row.failure_class ? FAILURE_CLASS_LABELS[row.failure_class] : "Failed"}
          {row.failures > 1 ? ` · ${row.failures} times` : ""}
        </span>
      ),
    },
    {
      key: "when",
      header: "Last failed",
      cell: (row) => (row.last_failed_at ? <time title={absoluteTime(row.last_failed_at)}>{relativeTime(row.last_failed_at)}</time> : "—"),
    },
    {
      key: "state",
      header: "Now",
      cell: (row) =>
        row.active ? (
          <Badge tone="warning">Skipped{row.retry_at ? ` until ${absoluteTime(row.retry_at)}` : ""}</Badge>
        ) : (
          <Badge tone="success">Tried again</Badge>
        ),
    },
    {
      key: "forget",
      header: "",
      srHeader: "Forget",
      cell: (row) => (
        <ConfirmButton variant="secondary" question="Try this way again next time?" disabled={forget.isPending} onConfirm={() => forget.mutate(row.id)}>
          Forget
        </ConfirmButton>
      ),
    },
  ];

  return (
    <div className="space-y-3">
      <DataTable caption="What plays have taught" columns={columns} rows={rows} rowKey={(row) => row.id} sort={sort} onSortChange={setSort} presorted />
      <Pager page={page} per={PER} total={lessons.data.total} onChange={setPage} noun="lessons" />
    </div>
  );
}
