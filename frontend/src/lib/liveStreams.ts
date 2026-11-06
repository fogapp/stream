import { Cctv, Globe, MonitorPlay, Tv, type LucideIcon } from "lucide-react";
import type { LiveStreamFeed, LiveStreamKind, LiveStreamStatus, LiveStreamTrack } from "@/types";

interface LiveStreamKindOption {
  label: string;
  icon: LucideIcon;
  hint: string;
  placeholder: string;
  /** Its address can carry a password or token, so it's typed hidden. */
  secret: boolean;
  /** It can have a certificate of its own to trust. */
  certificate: boolean;
}

export const LIVE_STREAM_KIND_OPTIONS: Record<LiveStreamKind, LiveStreamKindOption> = {
  camera: {
    label: "Camera",
    icon: Cctv,
    hint: "On your network, usually RTSP. Kept as close to live as the camera allows.",
    placeholder: "rtsps://192.168.1.1:7441/…",
    secret: true,
    certificate: true,
  },
  web: {
    label: "Web stream",
    icon: Globe,
    hint: "One HLS (.m3u8) or DASH (.mpd) stream from the web.",
    placeholder: "https://example.com/live/index.m3u8",
    secret: true,
    certificate: true,
  },
  youtube: {
    label: "YouTube",
    icon: MonitorPlay,
    hint: "A live stream's link, or a channel's: a channel plays whatever it has live, even after YouTube restarts the stream.",
    placeholder: "https://www.youtube.com/watch?v=… or https://www.youtube.com/@channel",
    secret: false,
    certificate: false,
  },
  mlb: {
    label: "MLB.tv",
    icon: Tv,
    hint: "One game's link from MLB.tv, while it's on. Baseball in the sidebar plays every game without one; both sign in with the account in Settings › Integrations.",
    placeholder: "https://www.mlb.com/tv/g745652/…",
    secret: false,
    certificate: false,
  },
};

export const LIVE_STREAM_FEED_LABELS: Record<LiveStreamFeed, string> = { home: "Home team's broadcast", away: "Away team's broadcast" };

const YOUTUBE_HOSTS = /^(https?:\/\/)?((www|m|music)\.)?(youtube\.com|youtu\.be)(\/|$)/i;
const MLB_HOSTS = /^(https?:\/\/)?(www\.)?mlb\.com(\/|$)/i;

/** The kind a typed address can only be: a YouTube or MLB.tv link plays only as its own kind. */
export function kindOfLink(address: string): LiveStreamKind | null {
  const trimmed = address.trim();
  if (YOUTUBE_HOSTS.test(trimmed)) return "youtube";
  if (MLB_HOSTS.test(trimmed)) return "mlb";
  return null;
}

export const LIVE_STREAM_STATUS_LABELS: Record<LiveStreamStatus, string> = { online: "Online", offline: "Offline" };


/** The ratings a stream can be given; "" is unrated. */
export const LIVE_STREAM_RATINGS = ["", "TV-Y", "TV-G", "TV-PG", "TV-14", "TV-MA"] as const;

const CODECS: Record<string, string> = {
  h264: "H.264",
  hevc: "HEVC",
  av1: "AV1",
  vp9: "VP9",
  aac: "AAC",
  opus: "Opus",
  ac3: "Dolby Digital",
  eac3: "Dolby Digital Plus",
  mp3: "MP3",
  pcm_mulaw: "G.711 µ-law",
  pcm_alaw: "G.711 A-law",
};

function codecLabel(codec: string | null): string {
  if (!codec) return "Unknown";
  return CODECS[codec] ?? codec.toUpperCase();
}

function channelsLabel(channels: number | null): string | null {
  if (channels === 1) return "mono";
  if (channels === 2) return "stereo";
  if (channels === 6) return "5.1";
  return channels ? `${channels}-channel` : null;
}

/** "H.264 3840×2160 24 fps · AAC mono · Opus stereo" */
export function describeTracks(tracks: LiveStreamTrack[]): string {
  return [...tracks]
    .sort((a, b) => (a.kind === b.kind ? 0 : a.kind === "video" ? -1 : 1))
    .map((track) =>
      track.kind === "video"
        ? [
            codecLabel(track.codec),
            track.width && track.height ? `${track.width}×${track.height}` : null,
            track.frame_rate ? `${Math.round(track.frame_rate)} fps` : null,
          ]
            .filter(Boolean)
            .join(" ")
        : [codecLabel(track.codec), channelsLabel(track.channels)].filter(Boolean).join(" "),
    )
    .join(" · ");
}
