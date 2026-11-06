import { Link } from "react-router-dom";
import { ArrowLeft, Film, Play, Trash2, WifiOff } from "lucide-react";
import { useOfflineItems } from "@/hooks/useOfflineItems";
import { formatBytes } from "@/lib/bytes";
import { offlineSupported, removeDownload } from "@/lib/offline/downloads";
import type { OfflineItem } from "@/lib/offline/store";
import { useOnline } from "@/hooks/useOnline";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { EmptyState, LoadingState } from "@/components/ui/PageState";
import { PageHeader } from "@/components/layout/PageHeader";

/**
 * Downloads (PROPOSAL §11 Phase 6): what's saved in this browser, playable
 * with no network at all. Online it's a page like any other; the list asks
 * the server for nothing, so offline it stands alone as `OfflineDownloads`.
 */
export function Downloads() {
  return (
    <div className="space-y-6 px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
      <PageHeader title="Downloads" description="Saved in this browser, to watch without a network." />
      <DownloadList />
    </div>
  );
}

/** Where the app lands when the server can't be reached: no shell, since the shell needs the profile. */
export function OfflineDownloads() {
  const online = useOnline();

  return (
    <div className="min-h-dvh bg-background">
      <header className="flex items-center gap-3 border-b border-border px-4 py-4 sm:px-6 lg:px-8">
        {online ? (
          <Link to="/downloads" className="inline-flex items-center gap-1.5 text-sm text-muted hover:text-foreground">
            <ArrowLeft className="h-4 w-4" aria-hidden /> Stream
          </Link>
        ) : (
          <span className="inline-flex items-center gap-1.5 text-sm text-muted">
            <WifiOff className="h-4 w-4" aria-hidden /> Offline
          </span>
        )}
        <h1 className="text-lg font-semibold text-foreground">Downloads</h1>
      </header>
      <main className="px-4 py-4 sm:px-6 lg:px-8 lg:py-6">
        <DownloadList />
      </main>
    </div>
  );
}

function DownloadList() {
  const { items, loaded } = useOfflineItems();

  if (!offlineSupported()) {
    return <EmptyState title="Downloads need a secure connection" description="Open Stream over HTTPS to save things for offline." />;
  }
  if (!loaded) return <LoadingState />;
  if (items.length === 0) {
    return <EmptyState title="Nothing downloaded" description="Download a film, an episode or a video from its page to watch it without a network." />;
  }
  return (
    <ul className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
      {items.map((item) => (
        <DownloadRow key={item.id} item={item} />
      ))}
    </ul>
  );
}

function DownloadRow({ item }: { item: OfflineItem }) {
  const percent = item.size > 0 ? Math.min(100, Math.round((item.received / item.size) * 100)) : 0;
  return (
    <li className="flex gap-3 rounded-[var(--radius-card)] border border-border bg-surface p-3">
      <div className="flex h-24 w-16 shrink-0 items-center justify-center overflow-hidden rounded bg-surface-raised">
        {item.hasPoster ? <img src={`/offline/${item.id}/poster`} alt="" className="h-full w-full object-cover" /> : <Film className="h-6 w-6 text-muted" aria-hidden />}
      </div>
      <div className="min-w-0 flex-1 space-y-1.5 text-sm">
        <p className="truncate font-medium text-foreground">{item.title}</p>
        {item.subtitle ? <p className="truncate text-muted">{item.subtitle}</p> : null}
        <p className="flex flex-wrap items-center gap-2 text-xs text-muted">
          {item.state === "done" ? <Badge tone="success">Ready</Badge> : item.state === "failed" ? <Badge tone="danger">Failed</Badge> : <Badge tone="info">{percent}%</Badge>}
          {formatBytes(item.size)}
          {item.optimized ? " · optimized version" : ""}
        </p>
        {item.state === "downloading" ? (
          <div className="h-1.5 overflow-hidden rounded-full bg-surface-raised" role="progressbar" aria-valuenow={percent} aria-valuemin={0} aria-valuemax={100} aria-label={`Downloading ${item.title}`}>
            <div className="h-full bg-primary" style={{ width: `${percent}%` }} />
          </div>
        ) : null}
        {item.error ? <p className="text-xs text-negative">{item.error}</p> : null}
        <div className="flex flex-wrap gap-2 pt-1">
          {item.state === "done" ? (
            <Link to={`/downloads/${item.id}`} className="inline-flex h-8 items-center gap-1.5 rounded-[var(--radius-control)] bg-primary px-3 text-sm text-primary-foreground hover:bg-primary-hover">
              <Play className="h-4 w-4" aria-hidden /> {item.position > 0 ? "Resume" : "Play"}
            </Link>
          ) : null}
          <ConfirmButton size="sm" variant="ghost" question="Remove it from this browser?" onConfirm={() => void removeDownload(item.id)}>
            <Trash2 className="h-4 w-4" aria-hidden /> Remove
          </ConfirmButton>
          {item.state === "failed" ? (
            <Button size="sm" variant="ghost" onClick={() => void removeDownload(item.id)}>
              Clear
            </Button>
          ) : null}
        </div>
      </div>
    </li>
  );
}
