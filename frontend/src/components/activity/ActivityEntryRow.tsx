import { ArrowUpRight } from "lucide-react";
import { Link } from "react-router-dom";
import { ACTIVITY_SEVERITY_TONES } from "@/lib/activity";
import { scalarChips } from "@/lib/chips";
import { formatMillis } from "@/lib/numbers";
import { absoluteTime, relativeTime } from "@/lib/time";
import { Badge } from "@/components/ui/Badge";
import { KeyValueChips } from "@/components/ui/KeyValueChips";
import type { ActivityEntry } from "@/types";

/** Payload keys that repeat what the row already says beside them. */
const REDUNDANT_KEYS = new Set(["source_id", "item_id", "job_id"]);
const MAX_CHIPS = 6;

export function ActivityEntryRow({
  entry,
  timeStyle = "clock",
}: {
  entry: ActivityEntry;
  /** "clock" on the log, where the page is a sequence; "relative" on the
   *  dashboard, where the question is how long ago. */
  timeStyle?: "clock" | "relative";
}) {
  // The numbers behind the sentence (`enqueued: 12`); nested values fold to
  // short JSON rather than "[object Object]", and the rest is left to the trace.
  const chips = scalarChips(entry.payload, { skip: REDUNDANT_KEYS, max: MAX_CHIPS, foldObjects: true });
  const subject = entry.subject;
  return (
    <div className="flex items-start gap-3 px-4 py-3 sm:gap-4 sm:px-5">
      <Badge tone={ACTIVITY_SEVERITY_TONES[entry.severity]} className="mt-0.5">
        {entry.severity}
      </Badge>
      <div className="min-w-0 flex-1">
        <p className="text-sm text-foreground">{entry.summary}</p>
        <p className="mt-0.5 flex flex-wrap items-center gap-x-1 font-mono text-xs text-muted">
          <span>
            {entry.source} · {entry.event}
            {entry.duration_ms === null ? "" : ` · ${formatMillis(entry.duration_ms)}`}
          </span>
          {subject ? (
            subject.path && subject.label ? (
              <Link
                to={subject.path}
                className="inline-flex items-center gap-0.5 font-sans text-foreground hover:underline"
              >
                <span className="text-muted">·</span> {subject.label}
                <ArrowUpRight className="h-3 w-3 text-muted" aria-hidden />
              </Link>
            ) : (
              <span title={subject.id}>
                · {subject.type}
                {subject.label ? ` ${subject.label}` : " (deleted)"}
              </span>
            )
          ) : null}
        </p>
        <KeyValueChips entries={chips} className="mt-1" />
      </div>
      <time
        className="shrink-0 text-xs text-muted"
        dateTime={entry.created_at}
        title={absoluteTime(entry.created_at)}
      >
        {timeStyle === "relative"
          ? relativeTime(entry.created_at)
          : new Date(entry.created_at).toLocaleTimeString()}
      </time>
    </div>
  );
}
