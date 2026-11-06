import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import type { NextItem, PlayableKind, VideoCard, VideoDetail } from "@/types";

export type Offers = NonNullable<VideoDetail["end_screen"]>;

/**
 * What a finished video offers (PROPOSAL §5.4), read from its watch page's
 * own query so the two share one cache entry. null when it isn't a video,
 * Settings › YouTube turned it off, or there's nothing to offer.
 */
export function useEndScreen(item: { kind: PlayableKind; id: string }): Offers | null {
  const video = item.kind === "video";
  const detail = useQuery({
    enabled: video,
    queryKey: keys.videos.detail(item.id),
    queryFn: ({ signal }) => api.get<VideoDetail>(`/videos/${item.id}`, { signal }),
  });
  const offers = video ? detail.data?.end_screen : null;
  return offers && (offers.next || offers.others.length > 0) ? offers : null;
}

export function asNext(card: VideoCard): NextItem {
  return { kind: "video", id: card.id, code: null, title: card.title, show_title: card.channel?.title ?? null, image: card.images.thumb ?? null, playlist_id: null };
}

const AUTOPLAY_KEY = "stream_end_screen_autoplay";

/** Whether a finished video plays one of its offers by itself (this browser remembers). */
export function storedAutoplay(): boolean {
  try {
    return localStorage.getItem(AUTOPLAY_KEY) === "on";
  } catch {
    return false;
  }
}

export function rememberAutoplay(on: boolean) {
  try {
    localStorage.setItem(AUTOPLAY_KEY, on ? "on" : "off");
  } catch {
    // A nicety.
  }
}

/**
 * What autoplay plays: the first offer not yet watched, the channel's own
 * first; when every one has been watched, the channel's anyway.
 */
export function autoplayPick(offers: Offers): VideoCard | null {
  const all = offers.next ? [offers.next, ...offers.others] : offers.others;
  return all.find((card) => !card.watched) ?? all[0] ?? null;
}
