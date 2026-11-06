import type { BadgeTone } from "@/components/ui/Badge";
import type { FailureClass, PlaybackMethod, PlaybackOutcome } from "@/types";

export const PLAYBACK_METHOD_LABELS: Record<PlaybackMethod, string> = {
  direct: "Direct",
  remux: "Repackaged",
  audio_transcode: "Audio converted",
  optimized: "Optimized version",
  video_transcode: "Video converted",
};

export const PLAYBACK_METHOD_TONES: Record<PlaybackMethod, BadgeTone> = {
  direct: "success",
  remux: "info",
  audio_transcode: "info",
  optimized: "info",
  video_transcode: "warning",
};

export const PLAYBACK_OUTCOME_LABELS: Record<PlaybackOutcome, string> = {
  failed: "Conversion failed",
  errored: "Player error",
  stalled: "Stalled",
  clean: "Fine",
};

export const PLAYBACK_OUTCOME_TONES: Record<PlaybackOutcome, BadgeTone> = {
  failed: "danger",
  errored: "danger",
  stalled: "warning",
  clean: "success",
};

/** How a play failed (PlaybackSession::FailureClass), for the Learned table. */
export const FAILURE_CLASS_LABELS: Record<FailureClass, string> = {
  decode: "Couldn't decode it",
  unsupported: "Wouldn't open it",
  stalled: "Stalled",
  network: "Network",
  server: "Transcoder gave up",
};
