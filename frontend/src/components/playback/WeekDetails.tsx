import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { ChevronRight } from "lucide-react";
import { api } from "@/api/client";
import { cn } from "@/lib/cn";
import { ENCODER_LABELS } from "@/lib/encoders";
import { PLAYBACK_METHOD_LABELS } from "@/lib/playback";
import { keys } from "@/lib/queryKeys";
import { QueryState } from "@/components/ui/PageState";
import { PLAYBACK_METHODS, type PlaybackMethod, type PlaybackSummary, type TimingSpread } from "@/types";
import { plural } from "@/lib/format";

/** The targets in PROPOSAL §6.4, for a line to measure against. */
const STARTUP_TARGET_MS: Partial<Record<PlaybackMethod, number>> = { direct: 800, remux: 1500, video_transcode: 3000 };

/**
 * The week's raw numbers — how plays split by method, the commonest
 * reasons, start-up and seek times, Grid changes — behind a disclosure:
 * there when wanted, out of the way of the health checks.
 */
export function WeekDetails() {
  const [open, setOpen] = useState(false);
  const summary = useQuery({
    queryKey: keys.playbackDecisions.summary(),
    queryFn: ({ signal }) => api.get<PlaybackSummary>("/playback_decisions/summary", { signal }),
    enabled: open,
  });

  return (
    <section className="rounded-[var(--radius-card)] border border-border">
      <button
        type="button"
        aria-expanded={open}
        onClick={() => setOpen((value) => !value)}
        className="flex w-full items-center gap-2 px-4 py-3 text-left text-sm font-medium text-foreground hover:bg-surface-raised"
      >
        <ChevronRight className={cn("h-4 w-4 text-muted transition-transform", open && "rotate-90")} aria-hidden />
        This week in detail
      </button>
      {open ? (
        <div className="border-t border-border px-4 py-4">
          <QueryState query={summary} errorMessage="Could not load the week's numbers.">
            {(week) => <Week week={week} />}
          </QueryState>
        </div>
      ) : null}
    </section>
  );
}

function share(count: number, total: number): string {
  return total ? `${Math.round((count / total) * 100)}%` : "—";
}

function spreadLabel(spread: TimingSpread): string {
  return `typically ${spread.median_ms} ms, ${spread.p95_ms} ms at worst for 19 in 20 (${spread.count})`;
}

function Week({ week }: { week: PlaybackSummary }) {
  const timed = PLAYBACK_METHODS.filter((method) => week.startup[method].count > 0);
  return (
    <div className="grid gap-6 text-sm lg:grid-cols-2">
      <div className="space-y-2">
        <p className="font-medium text-foreground">How {plural(week.total, "play")} went</p>
        <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-muted">
          {PLAYBACK_METHODS.map((method) => (
            <div key={method} className="contents">
              <dt className="text-foreground">{PLAYBACK_METHOD_LABELS[method]}</dt>
              <dd className="tabular-nums">
                {week.methods[method]} ({share(week.methods[method], week.total)})
              </dd>
            </div>
          ))}
        </dl>
        <p className="text-muted">
          Converting now: {week.converting_now} of {week.cap} allowed ({ENCODER_LABELS[week.encoder]} here
          {week.remote_transcoders > 0 ? `, plus ${week.remote_transcoders} remote transcoder${week.remote_transcoders === 1 ? "" : "s"}` : ""}).{" "}
          Players reported {plural(week.stalls, "stall")}, {week.recoveries} recover{week.recoveries === 1 ? "y" : "ies"} and{" "}
          {plural(week.errors, "error")}.
        </p>
      </div>
      <div className="space-y-4">
        {week.top_reasons.length > 0 ? (
          <div>
            <p className="font-medium text-foreground">Most common reasons</p>
            <ol className="mt-1 list-decimal space-y-1 pl-5 text-muted">
              {week.top_reasons.map((reason) => (
                <li key={reason.summary}>
                  {reason.summary} <span className="tabular-nums">({reason.count})</span>
                </li>
              ))}
            </ol>
          </div>
        ) : null}
        {timed.length > 0 || week.seeks.count > 0 ? (
          <div>
            <p className="font-medium text-foreground">Time to the first frame</p>
            <ul className="mt-1 space-y-1 text-muted">
              {timed.map((method) => {
                const target = STARTUP_TARGET_MS[method];
                return (
                  <li key={method}>
                    <span className="text-foreground">{PLAYBACK_METHOD_LABELS[method]}:</span> {spreadLabel(week.startup[method])}
                    {target ? `; aiming for under ${target} ms` : ""}
                  </li>
                );
              })}
              {week.seeks.count > 0 ? (
                <li>
                  <span className="text-foreground">Seeking past what was buffered:</span> {spreadLabel(week.seeks)}
                </li>
              ) : null}
            </ul>
          </div>
        ) : null}
        {week.channel_changes.count > 0 || week.program_changes.count > 0 ? (
          <div className="space-y-1 text-muted">
            <p className="font-medium text-foreground">Grid</p>
            {week.channel_changes.count > 0 ? (
              <p>
                {week.channel_changes.count} channel change{week.channel_changes.count === 1 ? "" : "s"}, {week.channel_changes.ready} to a
                channel tuned ahead; first frame in {week.channel_changes.median_ms} ms typically, {week.channel_changes.p90_ms} ms at worst
                for nine in ten.
              </p>
            ) : null}
            {week.program_changes.count > 0 ? (
              <p>
                {plural(week.program_changes.count, "program")} gave way to the next,{" "}
                {week.program_changes.ready} tuned ahead
                {week.program_changes.median_ms !== null
                  ? `; the next's first frame ${week.program_changes.median_ms} ms after the end typically, ${week.program_changes.p90_ms} ms at worst for nine in ten`
                  : ""}
                .
                {week.program_changes.watchdog > 0
                  ? ` ${week.program_changes.watchdog} only moved on because the picture stuck at the end.`
                  : ""}
              </p>
            ) : null}
          </div>
        ) : null}
      </div>
    </div>
  );
}
