import { useState } from "react";
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { ActivityEntryRow } from "@/components/activity/ActivityEntryRow";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { EmptyState, ErrorState, LoadingState } from "@/components/ui/PageState";
import type { ActivityEntry } from "@/types";

// The server's default page size; "Older" goes dark when a short page says
// the log has run out.
const PER_PAGE = 100;

export function ActivityLog() {
  const [errorsOnly, setErrorsOnly] = useState(false);
  const [page, setPage] = useState(1);
  const query = useQuery({
    queryKey: keys.activity.list(errorsOnly ? { severity: "error", page } : { page }),
    queryFn: ({ signal }) => {
      const params = new URLSearchParams({ page: String(page) });
      if (errorsOnly) params.set("severity", "error");
      // `/events`, not `/activity` — ad-blocker lists kill */activity URLs.
      return api.get<ActivityEntry[]>(`/events?${params.toString()}`, { signal });
    },
    placeholderData: keepPreviousData,
  });

  return (
    <>
      <PageHeader
        title="Activity"
        description="Every meaningful operation, with trace ids linking a request to the jobs it spawned."
        actions={
          <Button
            variant={errorsOnly ? "primary" : "secondary"}
            size="sm"
            onClick={() => {
              setErrorsOnly((value) => !value);
              setPage(1);
            }}
          >
            Errors only
          </Button>
        }
      />
      <div className="px-4 py-4 sm:px-6 lg:px-8 lg:py-6">
        {query.isPending ? (
          <LoadingState />
        ) : query.isError ? (
          <ErrorState message="Could not load the activity log." onRetry={() => query.refetch()} />
        ) : query.data.length === 0 && page === 1 ? (
          <EmptyState
            title="Nothing recorded yet"
            description="Ingestion runs, job failures, and integration events will show up here."
          />
        ) : query.data.length === 0 ? (
          <p className="text-sm text-muted">Nothing older — the log ends here.</p>
        ) : (
          <Card className="divide-y divide-border">
            {query.data.map((entry) => (
              <ActivityEntryRow key={entry.id} entry={entry} />
            ))}
          </Card>
        )}

        {!query.isPending && !query.isError ? (
          <div className="mt-4 flex items-center justify-between">
            <Button
              variant="secondary"
              size="sm"
              onClick={() => setPage((value) => Math.max(1, value - 1))}
              disabled={page === 1}
            >
              <ChevronLeft className="mr-1 h-4 w-4" aria-hidden /> Newer
            </Button>
            <span className="text-xs text-muted">Page {page}</span>
            <Button
              variant="secondary"
              size="sm"
              onClick={() => setPage((value) => value + 1)}
              disabled={query.data.length < PER_PAGE}
            >
              Older <ChevronRight className="ml-1 h-4 w-4" aria-hidden />
            </Button>
          </div>
        ) : null}
      </div>
    </>
  );
}
