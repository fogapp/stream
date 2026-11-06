import { useEffect, useRef, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { Button } from "@/components/ui/Button";
import { ArrowLeft } from "lucide-react";
import { getItem, listItems, savePosition, syncPositions } from "@/lib/offline/downloads";
import type { OfflineItem } from "@/lib/offline/store";
import { EmptyState, LoadingState } from "@/components/ui/PageState";

const SKIP_LABELS = { intro: "Skip intro", recap: "Skip recap", credits: "Skip credits" } as const;

/** How often the place is saved while watching. */
const SAVE_EVERY_MS = 5_000;

/**
 * Watching a download (PROPOSAL §11 Phase 6), with no network: the
 * browser's own player over what the service worker serves from storage,
 * with its subtitles. Where the viewer got to is kept on the device and
 * told to the server once it's back.
 */
export function OfflineWatch() {
  const { id = "" } = useParams();
  const [item, setItem] = useState<OfflineItem | null | undefined>(undefined);
  const video = useRef<HTMLVideoElement>(null);
  const lastSave = useRef(0);
  const navigate = useNavigate();
  const [now, setNow] = useState(0);
  const [next, setNext] = useState<OfflineItem | null>(null);
  const skipped = useRef(new Set<string>());

  // The next episode, if it's downloaded and ready too.
  useEffect(() => {
    if (!item?.nextEpisodeId) return;
    void listItems().then((items) =>
      setNext(items.find((candidate) => candidate.playable.id === item.nextEpisodeId && candidate.state === "done") ?? null),
    );
  }, [item]);
  const marker = item?.markers?.find((candidate) => now >= candidate.start && now < candidate.end - 1) ?? null;
  const nearEnd = item?.durationSeconds ? now >= item.durationSeconds - 15 : false;

  // What the profile always skips, skipped here too.
  useEffect(() => {
    const element = video.current;
    if (!element || !marker || !item?.skip?.[marker.kind] || skipped.current.has(marker.kind)) return;
    skipped.current.add(marker.kind);
    if (marker.kind === "credits" && next) navigate(`/downloads/${next.id}`, { replace: true });
    else element.currentTime = marker.end;
  }, [marker, item, next, navigate]);

  useEffect(() => {
    void getItem(id).then((found) => setItem(found ?? null));
  }, [id]);

  useEffect(() => {
    const element = video.current;
    if (!element || !item) return;
    const save = (force: boolean) => {
      const now = Date.now();
      if (!force && now - lastSave.current < SAVE_EVERY_MS) return;
      lastSave.current = now;
      void savePosition(item.id, element.ended ? (element.duration || element.currentTime) : element.currentTime).then(() => syncPositions());
    };
    const onTime = () => {
      setNow(element.currentTime);
      save(false);
    };
    const onStop = () => save(true);
    const onEnded = () => {
      if (next) navigate(`/downloads/${next.id}`, { replace: true });
    };
    element.addEventListener("ended", onEnded);
    element.addEventListener("timeupdate", onTime);
    element.addEventListener("pause", onStop);
    element.addEventListener("ended", onStop);
    return () => {
      onStop();
      element.removeEventListener("timeupdate", onTime);
      element.removeEventListener("pause", onStop);
      element.removeEventListener("ended", onStop);
      element.removeEventListener("ended", onEnded);
    };
  }, [item, next, navigate]);

  if (item === undefined) return <LoadingState />;
  if (item === null || item.state !== "done") {
    return (
      <div className="min-h-dvh bg-background p-6">
        <EmptyState title="Not downloaded" description="It isn't saved in this browser (any more)." action={<Link to="/downloads" className="text-primary hover:underline">Downloads</Link>} />
      </div>
    );
  }

  const finishedBefore = item.durationSeconds ? item.position > item.durationSeconds * 0.95 : false;
  return (
    <div className="relative flex min-h-dvh flex-col bg-background">
      <header className="flex items-center gap-3 px-4 py-3">
        <Link to="/downloads" className="inline-flex items-center gap-1.5 text-sm text-muted hover:text-foreground">
          <ArrowLeft className="h-4 w-4" aria-hidden /> Downloads
        </Link>
        <p className="min-w-0 truncate text-sm text-foreground">
          {item.title}
          {item.subtitle ? <span className="text-muted"> · {item.subtitle}</span> : null}
        </p>
      </header>
      <video
        ref={video}
        className="w-full flex-1 bg-background"
        src={`/offline/${item.id}/file`}
        controls
        autoPlay
        playsInline
        onLoadedMetadata={(event) => {
          if (item.position > 0 && !finishedBefore) event.currentTarget.currentTime = item.position;
        }}
      >
        {item.subtitles.map((track) => (
          <track key={track.id} kind="subtitles" label={track.label} srcLang={track.language ?? undefined} src={`/offline/${item.id}/subtitles/${track.id}.vtt`} default={track.forced} />
        ))}
      </video>
      <div className="pointer-events-none absolute bottom-24 right-6 flex flex-col items-end gap-2">
        {marker && !(marker.kind === "credits" && next) ? (
          <Button className="pointer-events-auto" variant="secondary" onClick={() => video.current && (video.current.currentTime = marker.end)}>
            {SKIP_LABELS[marker.kind]}
          </Button>
        ) : null}
        {next && (nearEnd || marker?.kind === "credits") ? (
          <Button className="pointer-events-auto" onClick={() => navigate(`/downloads/${next.id}`, { replace: true })}>
            Next: {next.subtitle ?? next.title}
          </Button>
        ) : null}
      </div>
    </div>
  );
}
