import { ListEnd } from "lucide-react";
import { usePlaybackActions, usePlayingTitle } from "@/hooks/usePlayback";
import { toast } from "@/components/ui/Toast";
import { Button } from "@/components/ui/Button";
import { IconButton } from "@/components/ui/IconButton";
import type { NextItem } from "@/types";

/** Queue it after what's playing (PROPOSAL §5.4). Only there while something plays. */
export function PlayNextButton({ item, compact = false, className }: { item: NextItem; compact?: boolean; className?: string }) {
  // One on every tile: it re-renders when the title playing changes, not as it plays.
  const current = usePlayingTitle();
  const { enqueue } = usePlaybackActions();
  if (!current || current.id === item.id) return null;
  const add = () => {
    enqueue(item);
    toast.info(`${item.title ?? "It"} plays next`);
  };
  if (compact) {
    return (
      <IconButton label="Play next" onClick={add} className={className}>
        <ListEnd className="h-4 w-4" aria-hidden />
      </IconButton>
    );
  }
  return (
    <Button variant="ghost" onClick={add} className={className}>
      <ListEnd className="h-4 w-4" aria-hidden />
      Play next
    </Button>
  );
}

export function videoNext(video: { id: string; title: string; channel: { title: string } | null; images: { thumb?: NextItem["image"] } }): NextItem {
  return { kind: "video", id: video.id, code: null, title: video.title, show_title: video.channel?.title ?? null, image: video.images.thumb ?? null, playlist_id: null };
}
