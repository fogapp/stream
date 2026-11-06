import { useState } from "react";
import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ArrowUpRight, CheckCheck, ChevronLeft, ChevronRight } from "lucide-react";
import { Link } from "react-router-dom";
import { api } from "@/api/client";
import { cn } from "@/lib/cn";
import { notificationKindLabel, notificationKindTone } from "@/lib/notifications";
import { keys } from "@/lib/queryKeys";
import { absoluteTime, relativeTime } from "@/lib/time";
import { PageHeader } from "@/components/layout/PageHeader";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card } from "@/components/ui/Card";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import type { Notification, NotificationsResponse } from "@/types";

// The page size asked for; "Older" goes dark when a short page says the
// list has run out.
const PER_PAGE = 50;

/**
 * What the bell has been counting. Each row is the sentence Stream sent (and
 * pushed, if push is on) and, where it has one, a link to the thing it is
 * about. Following the link marks the row read; so does "Mark read" for any
 * row, and "Mark all read" for the lot.
 */
export function Notifications() {
  const queryClient = useQueryClient();
  const [page, setPage] = useState(1);
  const query = useQuery({
    queryKey: keys.notifications.list(page),
    queryFn: ({ signal }) => api.get<NotificationsResponse>(`/notifications?page=${page}&per=${PER_PAGE}`, { signal }),
    placeholderData: keepPreviousData,
  });
  const invalidate = () => void queryClient.invalidateQueries({ queryKey: keys.notifications.all });
  const readOne = useMutation({
    mutationFn: (id: string) => api.post(`/notifications/${id}/read`),
    onSuccess: invalidate,
  });
  const readAll = useMutation({
    mutationFn: () => api.post("/notifications/read_all"),
    onSuccess: invalidate,
  });
  const unread = query.data?.unread_count ?? 0;

  return (
    <>
      <PageHeader
        title="Notifications"
        description="What Stream wanted you to know: new episodes, finished scans, things that broke."
        actions={
          <Button variant="secondary" size="sm" onClick={() => readAll.mutate()} disabled={unread === 0 || readAll.isPending}>
            <CheckCheck className="h-4 w-4" aria-hidden />
            Mark all read
          </Button>
        }
      />
      <div className="px-4 py-4 sm:px-6 lg:px-8 lg:py-6">
        <QueryState
          query={query}
          errorMessage="Could not load your notifications."
          isEmpty={(data) => data.notifications.length === 0 && page === 1}
          empty={
            <EmptyState
              title="Nothing yet"
              description="When a scan finds something new or a library stops answering, it shows up here."
            />
          }
        >
          {(data) =>
            data.notifications.length === 0 ? (
              <p className="text-sm text-muted">Nothing older — the list ends here.</p>
            ) : (
              <Card className="divide-y divide-border">
                {data.notifications.map((row) => (
                  <NotificationRow
                    key={row.id}
                    row={row}
                    onRead={() => readOne.mutate(row.id)}
                    marking={readOne.isPending && readOne.variables === row.id}
                  />
                ))}
              </Card>
            )
          }
        </QueryState>

        {!query.isPending && !query.isError ? (
          <div className="mt-4 flex items-center justify-between">
            <Button variant="secondary" size="sm" onClick={() => setPage((value) => Math.max(1, value - 1))} disabled={page === 1}>
              <ChevronLeft className="mr-1 h-4 w-4" aria-hidden /> Newer
            </Button>
            <span className="text-xs text-muted">Page {page}</span>
            <Button
              variant="secondary"
              size="sm"
              onClick={() => setPage((value) => value + 1)}
              disabled={query.data.notifications.length < PER_PAGE}
            >
              Older <ChevronRight className="ml-1 h-4 w-4" aria-hidden />
            </Button>
          </div>
        ) : null}
      </div>
    </>
  );
}

function NotificationRow({ row, onRead, marking }: { row: Notification; onRead: () => void; marking: boolean }) {
  const unread = row.read_at === null;
  return (
    <div className={cn("flex items-start gap-3 px-4 py-3 sm:gap-4 sm:px-5", unread ? "bg-primary/5" : undefined)}>
      <span
        className={cn("mt-1.5 h-2 w-2 shrink-0 rounded-full", unread ? "bg-primary" : "bg-transparent")}
        role={unread ? "img" : undefined}
        aria-label={unread ? "Unread" : undefined}
        aria-hidden={unread ? undefined : true}
      />
      <span className="mt-0.5 w-5 shrink-0 text-center text-base leading-5" aria-hidden>
        {row.icon ?? ""}
      </span>
      <div className="min-w-0 flex-1">
        {row.path ? (
          <Link
            to={row.path}
            onClick={() => {
              if (unread) onRead();
            }}
            className={cn("inline-flex items-start gap-1 text-sm text-foreground hover:underline", unread ? "font-medium" : undefined)}
          >
            <span className="break-words">{row.title}</span>
            <ArrowUpRight className="mt-0.5 h-3.5 w-3.5 shrink-0 text-muted" aria-hidden />
          </Link>
        ) : (
          <p className={cn("break-words text-sm text-foreground", unread ? "font-medium" : undefined)}>{row.title}</p>
        )}
        <p className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-muted">
          <Badge tone={notificationKindTone(row.kind)}>{notificationKindLabel(row.kind)}</Badge>
          <span title={absoluteTime(row.created_at)}>{relativeTime(row.created_at)}</span>
          {row.read_at ? <span title={absoluteTime(row.read_at)}>read {relativeTime(row.read_at)}</span> : null}
        </p>
      </div>
      {unread ? (
        <Button variant="ghost" size="sm" className="shrink-0" onClick={onRead} disabled={marking}>
          Mark read
        </Button>
      ) : null}
    </div>
  );
}
