import { keys } from "@/lib/queryKeys";
import { seasonQuery, videoQuery } from "@/lib/queries";
import type {
  ClipDetail,
  EpisodeCard,
  ImageInfo,
  MovieCard,
  PlayableKind,
  PlaybackSessionInfo,
  PlaylistDetail,
  SeasonDetail,
  ShowCard,
  VideoCard,
  VideoDetail,
} from "@/types";

/** One thing the panel offers to play next. */
export interface RelatedItem {
  kind: "movie" | "episode" | "video" | "clip";
  id: string;
  title: string;
  detail: string | null;
  image: ImageInfo | null | undefined;
  progress: number | null;
  watched: boolean;
}

function fromCard(card: MovieCard | EpisodeCard | VideoCard): RelatedItem {
  switch (card.kind) {
    case "movie":
      return { kind: "movie", id: card.id, title: card.title, detail: card.year?.toString() ?? null,
        image: card.images.backdrop ?? card.images.thumb, progress: card.progress, watched: card.watched };
    case "episode":
      return { kind: "episode", id: card.id, title: card.title ?? card.code, detail: [card.show?.title, card.code].filter(Boolean).join(" · "),
        image: card.images.still ?? card.images.thumb, progress: card.progress, watched: card.watched };
    case "video":
      return { kind: "video", id: card.id, title: card.title, detail: card.channel?.title ?? null,
        image: card.images.thumb, progress: card.progress, watched: card.watched };
  }
}

export interface Related {
  title: string;
  /** The page the title stands for, when it has one. */
  href?: string;
  items: RelatedItem[];
}

/**
 * Where the panel's list comes from, given what's playing: a playlist's
 * items when it was started from one, else the episode's season, a movie's
 * nearest titles, the rest of a video's channel, a clip's same day. Each
 * reads the same key and path as its page, so they share one cache entry,
 * and `select` reshapes it.
 */
export function relatedSource(playing: { kind: PlayableKind; id: string }, session: PlaybackSessionInfo) {
  const { kind, id } = playing;
  const playlist = session.playlist_id;
  if (playlist) {
    return {
      queryKey: keys.playlists.detail(playlist),
      path: `/playlists/${playlist}`,
      select: (raw: unknown): Related => {
        const detail = raw as PlaylistDetail;
        return { title: detail.title, items: detail.items.map(fromCard) };
      },
    };
  }
  switch (kind) {
    case "episode": {
      if (!session.show_id || session.season_number === undefined) return null;
      const show = session.show_id;
      const number = session.season_number;
      return {
        queryKey: seasonQuery(show, number).queryKey,
        path: `/shows/${show}/seasons/${number}`,
        select: (raw: unknown): Related => {
          const detail = raw as SeasonDetail;
          return {
            title: detail.title,
            href: `/show/${show}?season=${number}`,
            items: detail.episodes.filter((episode) => episode.available).map((episode) => ({ ...fromCard(episode), detail: episode.title ? episode.code : null })),
          };
        },
      };
    }
    case "movie":
      return {
        queryKey: keys.movies.similar(id),
        path: `/movies/${id}/similar`,
        select: (raw: unknown): Related => ({
          title: "More like this",
          items: (raw as (MovieCard | ShowCard)[]).filter((card): card is MovieCard => card.kind === "movie").map(fromCard),
        }),
      };
    case "video":
      return {
        queryKey: videoQuery(id).queryKey,
        path: `/videos/${id}`,
        select: (raw: unknown): Related => {
          const detail = raw as VideoDetail;
          return { title: detail.channel ? `More from ${detail.channel.title}` : "More videos", items: detail.more_from_channel.map(fromCard) };
        },
      };
    case "clip":
      return {
        queryKey: keys.clips.detail(id),
        path: `/clips/${id}`,
        select: (raw: unknown): Related => ({
          title: "The same day",
          items: (raw as ClipDetail).same_day.map((clip) => ({
            kind: "clip" as const, id: clip.id, title: clip.title, detail: clip.city, image: clip.images.thumb, progress: clip.progress, watched: clip.watched,
          })),
        }),
      };
    case "extra":
      return null;
  }
}

/** Whether the player has anything to offer a panel for. */
export function hasRelated(playing: { kind: PlayableKind; id: string }, session: PlaybackSessionInfo) {
  return relatedSource(playing, session) !== null;
}

