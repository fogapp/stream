import { formatBytes } from "@/lib/bytes";
import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { formatClock } from "@/lib/format";
import { relativeTime } from "@/lib/time";
import { PageHeader } from "@/components/layout/PageHeader";
import { ProfileAvatar } from "@/components/profiles/ProfileAvatar";
import { ProgressBar } from "@/components/ui/ProgressBar";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import { Segmented } from "@/components/ui/Segmented";
import { StatTile } from "@/components/ui/StatTile";
import { PLAYBACK_METHOD_LABELS } from "@/lib/playback";
import type { NowPlayingSession, WatchSummary } from "@/types";

const RANGES = [
  { key: "7", label: "Week" },
  { key: "30", label: "Month" },
  { key: "365", label: "Year" },
] as const;

/** Tautulli in the box (PROPOSAL §7.4): who's watching now, and what's been watched. */
export function Stats() {
  const [days, setDays] = useState<"7" | "30" | "365">("30");
  const now = useQuery({ queryKey: keys.stats.nowPlaying(), queryFn: ({ signal }) => api.get<NowPlayingSession[]>("/stats/now_playing", { signal }), refetchInterval: 15_000 });
  const summary = useQuery({ queryKey: keys.stats.summary(Number(days)), queryFn: ({ signal }) => api.get<WatchSummary>(`/stats/summary?days=${days}`, { signal }) });

  return (
    <div className="space-y-6 px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
      <PageHeader title="Stats" description="What's playing now, and what's been watched." />
      <Card>
        <CardHeader title="Now playing" />
        <CardBody>
          <QueryState query={now} errorMessage="Could not load what's playing.">
            {(sessions) =>
              sessions.length === 0 ? (
                <p className="text-sm text-muted">Nothing right now.</p>
              ) : (
                <ul className="space-y-4">
                  {sessions.map((session) => (
                    <SessionRow key={session.id} session={session} live />
                  ))}
                </ul>
              )
            }
          </QueryState>
        </CardBody>
      </Card>

      <div className="flex items-center justify-between">
        <h2 className="text-base font-semibold text-foreground">Watched</h2>
        <Segmented segments={RANGES} value={days} onChange={setDays} label="Period" />
      </div>
      <QueryState query={summary} errorMessage="Could not load the numbers.">
        {(data) => <SummaryView summary={data} />}
      </QueryState>
      <History />
    </div>
  );
}

function SessionRow({ session, live = false }: { session: NowPlayingSession; live?: boolean }) {
  return (
    <li className="flex items-start gap-3">
      {session.profile ? <ProfileAvatar profile={session.profile} size="sm" /> : null}
      <div className="min-w-0 flex-1 space-y-1">
        <p className="truncate text-sm font-medium text-foreground">
          <Link to={session.back_path} className="hover:underline">
            {session.title}
          </Link>
          {session.subtitle ? <span className="text-muted"> · {session.subtitle}</span> : null}
        </p>
        <p className="truncate text-xs text-muted">
          {[session.profile?.name, session.device, session.bitrate_kbps ? `${(session.bitrate_kbps / 1000).toFixed(1)} Mb/s${session.bitrate_measured ? "" : " (file)"}` : null, live ? null : relativeTime(session.started_at)]
            .filter(Boolean)
            .join(" · ")}
        </p>
        {live && session.progress !== null ? (
          <div className="flex items-center gap-2">
            <ProgressBar variant="overlay" value={session.progress} className="h-1 flex-1 overflow-hidden rounded-full" />
            <span className="font-mono text-xs tabular-nums text-muted">
              {formatClock(session.position_seconds)} / {session.duration_seconds ? formatClock(session.duration_seconds) : "—"}
            </span>
          </div>
        ) : null}
      </div>
      <Badge tone={session.method === "video_transcode" ? "warning" : session.method === "direct" ? "success" : "info"}>
        {PLAYBACK_METHOD_LABELS[session.method]}
      </Badge>
    </li>
  );
}

function Bars({ rows }: { rows: { label: string; hours: number; plays: number }[] }) {
  const most = Math.max(...rows.map((row) => row.hours), 0.1);
  return (
    <ul className="space-y-2">
      {rows.map((row) => (
        <li key={row.label} className="space-y-1">
          <div className="flex justify-between text-sm">
            <span className="truncate text-foreground">{row.label}</span>
            <span className="shrink-0 tabular-nums text-muted">
              {row.hours} h · {row.plays} plays
            </span>
          </div>
          <div className="h-1.5 overflow-hidden rounded-full bg-surface-raised">
            <div className="h-full rounded-full bg-primary" style={{ width: `${(row.hours / most) * 100}%` }} />
          </div>
        </li>
      ))}
    </ul>
  );
}

function SummaryView({ summary }: { summary: WatchSummary }) {
  if (summary.plays === 0) return <EmptyState title="Nothing watched in this period" />;
  const peak = Math.max(...summary.by_day.map((day) => day.hours), 0.1);
  return (
    <div className="space-y-6">
      <div className="grid gap-4 sm:grid-cols-4">
        <StatTile label="Plays" value={summary.plays} />
        <StatTile label="Hours" value={summary.hours} />
        <StatTile label="Sent" value={formatBytes(summary.bytes_sent)} hint="What actually went over the network" />
        <StatTile label="Most watched" value={summary.most_watched[0]?.title ?? "—"} />
      </div>
      <Card>
        <CardHeader title="Each day" />
        <CardBody>
          <div className="flex h-32 items-end gap-0.5" role="img" aria-label="Hours watched each day">
            {summary.by_day.map((day) => (
              <div key={day.date} title={`${day.date}: ${day.hours} h`} className="flex-1 rounded-t bg-primary/70" style={{ height: `${Math.max((day.hours / peak) * 100, day.hours > 0 ? 3 : 0)}%` }} />
            ))}
          </div>
        </CardBody>
      </Card>
      <div className="grid gap-6 lg:grid-cols-3">
        <Card>
          <CardHeader title="By profile" />
          <CardBody>
            <Bars rows={summary.by_profile.map((row) => ({ label: row.name ?? "Unknown", hours: row.hours, plays: row.plays }))} />
          </CardBody>
        </Card>
        <Card>
          <CardHeader title="By library" />
          <CardBody>
            <Bars rows={summary.by_library.map((row) => ({ label: row.name, hours: row.hours, plays: row.plays }))} />
          </CardBody>
        </Card>
        <Card>
          <CardHeader title="Most watched" />
          <CardBody>
            <Bars rows={summary.most_watched.map((row) => ({ label: row.title, hours: row.hours, plays: row.plays }))} />
          </CardBody>
        </Card>
      </div>
    </div>
  );
}

function History() {
  const [page, setPage] = useState(1);
  const history = useQuery({ queryKey: keys.stats.history(page), queryFn: ({ signal }) => api.get<NowPlayingSession[]>(`/stats/history?page=${page}&per=25`, { signal }) });
  return (
    <Card>
      <CardHeader title="History" />
      <CardBody className="space-y-4">
        <QueryState query={history} errorMessage="Could not load the history.">
          {(sessions) =>
            sessions.length === 0 ? (
              <p className="text-sm text-muted">Nothing yet.</p>
            ) : (
              <ul className="space-y-3">
                {sessions.map((session) => (
                  <SessionRow key={session.id} session={session} />
                ))}
              </ul>
            )
          }
        </QueryState>
        <div className="flex justify-between">
          <Button variant="secondary" size="sm" disabled={page === 1} onClick={() => setPage((value) => value - 1)}>
            Newer
          </Button>
          <Button variant="secondary" size="sm" disabled={(history.data?.length ?? 0) < 25} onClick={() => setPage((value) => value + 1)}>
            Older
          </Button>
        </div>
      </CardBody>
    </Card>
  );
}
