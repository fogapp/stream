import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { PictureInPicture2, Plus, RefreshCw } from "lucide-react";
import { api } from "@/api/client";
import { useAuth } from "@/hooks/useAuth";
import { cn } from "@/lib/cn";
import { describeTracks, LIVE_STREAM_FEED_LABELS, LIVE_STREAM_KIND_OPTIONS, LIVE_STREAM_STATUS_LABELS } from "@/lib/liveStreams";
import { keys } from "@/lib/queryKeys";
import { librariesQuery } from "@/lib/queries";
import { relativeTime } from "@/lib/time";
import { PageHeader } from "@/components/layout/PageHeader";
import { TestResultLine } from "@/components/settings/TestResultLine";
import { LiveStreamForm } from "@/components/viewing/LiveStreamForm";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import { IconButton } from "@/components/ui/IconButton";
import { usePlayback } from "@/hooks/usePlayback";
import type { Library, LiveStream } from "@/types";
import { liveStreamsQuery } from "@/lib/queries";

/**
 * A live library (PROPOSAL §7.8): its cameras, web streams, YouTube live
 * streams and MLB.tv games. An admin adds, edits, checks and removes them
 * here, on the library they belong to.
 */
export function LiveLibrary({ library }: { library: Library }) {
  const { user } = useAuth();
  const admin = user?.role === "admin";
  const [adding, setAdding] = useState(false);
  const libraries = useQuery({ ...librariesQuery(), enabled: admin });
  const live = (libraries.data ?? []).filter((candidate) => candidate.kind === "live");
  const streams = useQuery(liveStreamsQuery(library.id));
  const addButton = (
    <Button size="sm" onClick={() => setAdding(true)}>
      <Plus className="h-4 w-4" aria-hidden />
      Add stream
    </Button>
  );

  return (
    <>
      <PageHeader
        title={library.name}
        description={
          admin
            ? "Cameras on your network, streams from the web, YouTube live streams and MLB.tv games. Stream relays them, so they play anywhere Stream does."
            : "Cameras and streams, live."
        }
        actions={admin && !adding ? addButton : null}
      />
      <div className="space-y-4 px-4 py-4 sm:px-6 lg:px-8 lg:py-6">
        {adding ? <LiveStreamForm library={library} libraries={live} onDone={() => setAdding(false)} /> : null}
        <QueryState
          query={streams}
          errorMessage="Could not load the streams."
          isEmpty={(list) => list.length === 0}
          empty={
            adding ? null : admin ? (
              <EmptyState title="No streams yet" description="Add a camera, a web stream, a YouTube live stream or an MLB.tv game by its address." action={addButton} />
            ) : (
              <EmptyState title="No streams yet" description="An admin adds cameras and web streams on this page." />
            )
          }
        >
          {(list) => (
            <ul className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3">
              {list.map((stream) => (
                <LiveStreamItem key={stream.id} stream={stream} library={library} libraries={live} admin={admin} />
              ))}
            </ul>
          )}
        </QueryState>
      </div>
    </>
  );
}

/** One stream in the grid; for an admin, with what it answered and its controls, or its form while editing. */
function LiveStreamItem({ stream, library, libraries, admin }: { stream: LiveStream; library: Library; libraries: Library[]; admin: boolean }) {
  const [editing, setEditing] = useState(false);

  if (editing) {
    return (
      <li className="col-span-full">
        <LiveStreamForm stream={stream} library={library} libraries={libraries} onDone={() => setEditing(false)} />
      </li>
    );
  }

  return (
    <li className="flex flex-col overflow-hidden rounded-[var(--radius-card)] border border-border bg-surface">
      <div className="relative">
        <LiveStreamTile stream={stream} />
        <PipOverTile stream={stream} />
      </div>
      {admin ? <LiveStreamAdmin stream={stream} onEdit={() => setEditing(true)} /> : null}
    </li>
  );
}

/** While something plays: this camera in the inset over it (picture in picture). */
function PipOverTile({ stream }: { stream: LiveStream }) {
  const { current, pip, openPip } = usePlayback();
  if (!current || (pip?.kind === "stream" && pip.id === stream.id)) return null;
  return (
    <IconButton
      label={`Picture in picture: ${stream.name}`}
      className="absolute right-2 top-2 rounded-full bg-background/80 text-foreground shadow-md hover:bg-background"
      onClick={() => openPip({ kind: "stream", id: stream.id, title: stream.name })}
    >
      <PictureInPicture2 className="h-4 w-4" aria-hidden />
    </IconButton>
  );
}

/** A stream's card: its latest picture, and whether it's answering. */
function LiveStreamTile({ stream }: { stream: LiveStream }) {
  const Icon = LIVE_STREAM_KIND_OPTIONS[stream.kind].icon;
  const offline = stream.status === "offline";
  return (
    <Link to={`/stream/${stream.id}`} className="group block transition-colors hover:bg-surface-raised">
      <div className="relative flex aspect-video items-center justify-center bg-surface-raised">
        {stream.still_url ? (
          <img src={stream.still_url} alt="" loading="lazy" className={cn("absolute inset-0 h-full w-full object-cover", offline && "opacity-40 grayscale")} />
        ) : (
          <Icon className="h-10 w-10 text-muted" aria-hidden />
        )}
        <span
          className={cn(
            "absolute left-2 top-2 flex items-center gap-1 rounded-[var(--radius-control)] px-1.5 py-0.5 text-xs font-semibold uppercase tracking-wide",
            offline ? "bg-surface text-negative" : "bg-negative text-negative-foreground",
          )}
        >
          {offline ? LIVE_STREAM_STATUS_LABELS.offline : "Live"}
        </span>
      </div>
      <div className="space-y-0.5 p-3">
        <p className="truncate font-medium text-foreground group-hover:text-primary">{stream.name}</p>
        <p className="truncate text-xs text-muted">
          {offline && stream.last_seen_at
            ? `Last seen ${relativeTime(stream.last_seen_at)}`
            : (stream.description ?? LIVE_STREAM_KIND_OPTIONS[stream.kind].label)}
        </p>
      </div>
    </Link>
  );
}

/** An admin's view of a stream: where it reads from, what it last answered, and Check now / Edit / Remove. */
function LiveStreamAdmin({ stream, onEdit }: { stream: LiveStream; onEdit: () => void }) {
  const queryClient = useQueryClient();
  const invalidate = () => queryClient.invalidateQueries({ queryKey: keys.liveStreams.all });
  const probe = useMutation({ mutationFn: () => api.post<LiveStream>(`/live_streams/${stream.id}/probe`), onSettled: invalidate });
  const remove = useMutation({ mutationFn: () => api.delete(`/live_streams/${stream.id}`), onSuccess: invalidate });

  return (
    <div className="mt-auto space-y-2 border-t border-border p-3">
      {stream.keep_connected ? <Badge>Kept connected</Badge> : null}
      <p className="break-all font-mono text-xs text-muted">
        {stream.source}
        {stream.feed ? <span className="font-sans"> · {LIVE_STREAM_FEED_LABELS[stream.feed]}</span> : null}
      </p>
      {stream.tracks.length > 0 ? <p className="text-xs text-foreground">{describeTracks(stream.tracks)}</p> : null}
      {stream.status === "offline" && stream.last_error ? (
        <TestResultLine ok={false} message={stream.last_error} at={stream.last_error_at} compact />
      ) : stream.last_seen_at ? (
        <p className="text-xs text-muted">Last read {relativeTime(stream.last_seen_at)}.</p>
      ) : null}
      <div className="flex flex-wrap items-center gap-2 pt-1">
        <Button variant="secondary" size="sm" onClick={() => probe.mutate()} disabled={probe.isPending}>
          <RefreshCw className="h-4 w-4" aria-hidden />
          {probe.isPending ? "Checking…" : "Check now"}
        </Button>
        <Button variant="ghost" size="sm" onClick={onEdit} aria-label={`Edit ${stream.name}`}>
          Edit
        </Button>
        <ConfirmButton onConfirm={() => remove.mutate()} question="Remove this stream? Nothing on the camera or site changes.">
          Remove
        </ConfirmButton>
      </div>
    </div>
  );
}
