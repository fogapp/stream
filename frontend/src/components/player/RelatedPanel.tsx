import { useEffect, useRef } from "react";
import { Link } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { Check, X } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { ProgressBar } from "@/components/ui/ProgressBar";
import { Button } from "@/components/ui/Button";
import { IconButton } from "@/components/ui/IconButton";
import { cn } from "@/lib/cn";
import type { PlayableKind, PlaybackSessionInfo } from "@/types";
import { relatedSource } from "@/components/player/related";
import { fromTv, tvPath } from "@/lib/tv";

function useRelated(item: { kind: PlayableKind; id: string }, session: PlaybackSessionInfo) {
  const source = relatedSource(item, session);
  return useQuery({
    enabled: source !== null,
    queryKey: source?.queryKey ?? keys.playback.all,
    queryFn: ({ signal }) => api.get<unknown>(source!.path, { signal }),
    select: (raw: unknown) => source!.select(raw),
  });
}

/**
 * The player's right-hand panel: related things to play instead, the one
 * playing marked. Choosing one plays it here, in the same player.
 */
export function RelatedPanel({
  item: playing,
  session,
  onClose,
}: {
  item: { kind: PlayableKind; id: string };
  session: PlaybackSessionInfo;
  onClose: () => void;
}) {
  const related = useRelated(playing, session);
  const panel = useRef<HTMLElement>(null);
  useEffect(() => {
    const list = panel.current?.querySelector("ul");
    (list?.querySelector<HTMLElement>('[aria-current="true"]') ?? list?.querySelector<HTMLElement>("a"))?.scrollIntoView({ block: "nearest" });
  }, [related.data]);

  return (
    <aside
      ref={panel}
      aria-label="Related"
      className="pointer-events-auto absolute inset-y-0 right-0 z-10 flex w-full flex-col sm:w-80 border-l border-border bg-surface shadow-xl sm:bg-surface/95"
      onClick={(event) => event.stopPropagation()}
      onDoubleClick={(event) => event.stopPropagation()}
    >
      <div className="flex items-center gap-2 border-b border-border px-4 py-3">
        <h2 className="min-w-0 flex-1 truncate font-semibold">
          {related.data?.href ? (
            <Link to={fromTv() ? tvPath(related.data.href) : related.data.href} className="hover:underline">
              {related.data.title}
            </Link>
          ) : (
            (related.data?.title ?? "Related")
          )}
        </h2>
        <IconButton label="Close related" onClick={onClose}>
          <X className="h-4 w-4" aria-hidden />
        </IconButton>
      </div>
      <div className="flex-1 overflow-y-auto p-2">
        {related.isPending ? <p className="px-2 py-3 text-sm text-muted">Loading…</p> : null}
        {related.isError ? (
          <div className="space-y-2 px-2 py-3">
            <p className="text-sm text-negative">Couldn't load what's related.</p>
            <Button variant="secondary" size="sm" onClick={() => void related.refetch()}>
              Try again
            </Button>
          </div>
        ) : null}
        {related.isSuccess && related.data.items.length === 0 ? <p className="px-2 py-3 text-sm text-muted">Nothing related yet.</p> : null}
        <ul className="space-y-1">
          {related.data?.items.map((item) => {
            const current = item.kind === playing.kind && item.id === playing.id;
            const href = `/watch/${item.kind}/${item.id}${session.playlist_id ? `?playlist=${session.playlist_id}` : ""}`;
            return (
              <li key={`${item.kind}:${item.id}`}>
                <Link
                  to={href}
                  replace
                  aria-current={current || undefined}
                  className={cn(
                    "flex gap-3 rounded-[var(--radius-control)] p-2 transition-colors hover:bg-surface-raised",
                    current && "bg-surface-raised ring-1 ring-primary",
                  )}
                >
                  <div className="relative w-28 shrink-0">
                    <ArtworkImage
                      image={item.image ?? null}
                      sizes="7rem"
                      className="aspect-video rounded-[var(--radius-control)] ring-1 ring-border"
                      fallback={<span className="px-1 text-center text-xs text-muted">{item.title}</span>}
                    />
                    {item.progress ? (
                      <ProgressBar variant="overlay" value={item.progress} className="absolute inset-x-0 bottom-0 overflow-hidden rounded-b-[var(--radius-control)]" />
                    ) : null}
                  </div>
                  <div className="min-w-0 flex-1">
                    <p className="line-clamp-2 text-sm font-medium leading-snug">{item.title}</p>
                    {item.detail ? <p className="truncate text-xs text-muted">{item.detail}</p> : null}
                    {current ? <p className="text-xs text-primary">Playing</p> : null}
                    {!current && item.watched ? (
                      <p className="flex items-center gap-1 text-xs text-muted">
                        <Check className="h-3 w-3" aria-hidden />
                        Watched
                      </p>
                    ) : null}
                  </div>
                </Link>
              </li>
            );
          })}
        </ul>
      </div>
    </aside>
  );
}
