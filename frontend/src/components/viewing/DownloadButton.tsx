import { useState } from "react";
import { Link } from "react-router-dom";
import { CircleCheck, Download, LoaderCircle } from "lucide-react";
import { ApiError } from "@/api/client";
import { useOfflineItems } from "@/hooks/useOfflineItems";
import { useProfile } from "@/hooks/useProfile";
import { DownloadError, offlineSupported, startDownload } from "@/lib/offline/downloads";
import { Button } from "@/components/ui/Button";
import { IconButton } from "@/components/ui/IconButton";
import { toast } from "@/components/ui/Toast";

type Downloadable = { type: "movie" | "episode" | "video" | "clip"; id: string };

/**
 * Save a title into this browser to watch without a network (PROPOSAL §11
 * Phase 6). Hidden where downloads can't work (no service worker: plain
 * HTTP). A button on pages, an icon on episode rows.
 */
export function DownloadButton({ item, compact = false }: { item: Downloadable; compact?: boolean }) {
  const { profile } = useProfile();
  const { items } = useOfflineItems();
  const [starting, setStarting] = useState(false);
  if (!offlineSupported()) return null;

  const saved = items.find((candidate) => candidate.playable.type === item.type && candidate.playable.id === item.id);
  const busy = starting || saved?.state === "downloading";
  const percent = saved && saved.size > 0 ? Math.round((saved.received / saved.size) * 100) : 0;

  async function start() {
    setStarting(true);
    try {
      await startDownload(item, profile?.id ?? null);
      toast.info("Downloading. It'll be in Downloads, ready to watch offline.");
    } catch (error) {
      toast.error(error instanceof ApiError || error instanceof DownloadError ? error.message : "The download didn't start.");
    } finally {
      setStarting(false);
    }
  }

  if (saved?.state === "done") {
    return compact ? (
      <IconButton label="Downloaded" onClick={() => undefined} disabled>
        <CircleCheck className="h-4 w-4" aria-hidden />
      </IconButton>
    ) : (
      <Link to="/downloads" className="inline-flex h-9 items-center gap-2 rounded-[var(--radius-control)] px-4 text-sm text-muted hover:bg-surface-raised hover:text-foreground">
        <CircleCheck className="h-4 w-4" aria-hidden /> Downloaded
      </Link>
    );
  }
  const Icon = busy ? LoaderCircle : Download;
  const label = busy ? `Downloading${percent ? ` ${percent}%` : "…"}` : "Download";
  if (compact) {
    return (
      <IconButton label={label} onClick={() => void start()} disabled={busy}>
        <Icon className={busy ? "h-4 w-4 animate-spin" : "h-4 w-4"} aria-hidden />
      </IconButton>
    );
  }
  return (
    <Button variant="ghost" onClick={() => void start()} disabled={busy}>
      <Icon className={busy ? "h-4 w-4 animate-spin" : "h-4 w-4"} aria-hidden />
      {label}
    </Button>
  );
}
