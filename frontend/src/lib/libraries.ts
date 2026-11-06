import { Camera, Cctv, Film, MonitorPlay, Tv, type LucideIcon } from "lucide-react";
import type { BadgeTone } from "@/components/ui/Badge";
import type { AnalysisStatus, AnalysisStep, LibraryKind, MatchState, MediaFileState, SponsorAction, SponsorCategory, YoutubeDownloadState } from "@/types";

export const LIBRARY_KIND_OPTIONS: Record<LibraryKind, { label: string; hint: string }> = {
  movies: { label: "Movies", hint: "One film per folder or file, e.g. Heat (1995)/Heat (1995).mkv" },
  shows: { label: "TV shows", hint: "Show / Season 01 / S01E01, as Sonarr and Plex lay them out" },
  home_videos: { label: "Home videos", hint: "Your own clips in any folders; placed in time by when they were taken" },
  channels: { label: "Channels", hint: "A folder per channel, as yt-dlp lays them out: Channel / Title [id].mkv with its .info.json" },
  live: { label: "Live", hint: "Cameras and web streams, added by address on the library's own page. No folders." },
};

export const LIBRARY_KIND_ICONS: Record<LibraryKind, LucideIcon> = {
  movies: Film,
  shows: Tv,
  channels: MonitorPlay,
  home_videos: Camera,
  live: Cctv,
};

export const MEDIA_FILE_STATE_LABELS: Record<MediaFileState, string> = {
  discovered: "Waiting to be read",
  probed: "Ready",
  broken: "Can't be read",
  missing: "Missing",
};

export const MEDIA_FILE_STATE_TONES: Record<MediaFileState, BadgeTone> = {
  discovered: "info",
  probed: "success",
  broken: "danger",
  missing: "warning",
};

export const MATCH_STATE_LABELS: Record<MatchState, string> = {
  matched: "Matched",
  needs_review: "Needs review",
  unmatched: "Unmatched",
};

export const ANALYSIS_STEP_LABELS: Record<AnalysisStep, string> = {
  probe: "Read streams",
  keyframes: "Keyframe index",
  match: "Match metadata",
  artwork: "Artwork",
  subtitles: "Extract subtitles",
  trickplay: "Seek-bar thumbnails",
  markers: "Intro and credits",
  loudness: "Loudness",
  transcript: "Transcript",
  subtitle_fetch: "Fetch missing subtitles",
  optimize: "Optimized version",
  youtube_details: "Details from YouTube",
};

export const ANALYSIS_STATUS_LABELS: Record<AnalysisStatus, string> = {
  pending: "Not run",
  running: "Running",
  succeeded: "Done",
  failed: "Failed",
};

export const ANALYSIS_STATUS_TONES: Record<AnalysisStatus, BadgeTone> = {
  pending: "neutral",
  running: "info",
  succeeded: "success",
  failed: "danger",
};

export const YOUTUBE_DOWNLOAD_STATE_LABELS: Record<YoutubeDownloadState, string> = {
  queued: "Waiting",
  downloading: "Downloading",
  done: "Downloaded",
  skipped: "Skipped",
  failed: "Failed",
  removed: "Removed (keep-last)",
};

export const YOUTUBE_DOWNLOAD_STATE_TONES: Record<YoutubeDownloadState, BadgeTone> = {
  queued: "neutral",
  downloading: "info",
  done: "success",
  skipped: "neutral",
  failed: "danger",
  removed: "neutral",
};

export const MAX_HEIGHTS = [360, 480, 720, 1080, 1440, 2160] as const;

export const SPONSOR_CATEGORY_LABELS: Record<SponsorCategory, { label: string; hint: string }> = {
  sponsor: { label: "Sponsor", hint: "A paid promotion" },
  selfpromo: { label: "Self-promotion", hint: "Their merch, their Patreon, a shout-out" },
  interaction: { label: "Interaction reminder", hint: "Like, subscribe, ring the bell" },
  intro: { label: "Intro", hint: "An animation or a jingle, no content" },
  outro: { label: "Endcards and credits", hint: "What comes after the video's done" },
  preview: { label: "Preview or recap", hint: "Clips of what's coming or what's been" },
  filler: { label: "Filler tangent", hint: "An aside, not needed for the main content" },
  music_offtopic: { label: "Non-music section", hint: "Talking in a music video" },
};

export const SPONSOR_ACTION_LABELS: Record<SponsorAction, string> = { skip: "Skip", ask: "Ask", show: "Show only" };
