import type { WhisperApiKind } from "@/types";

/** The Whisper servers Stream can talk to, as Settings offers them. */
export const WHISPER_API_KIND_OPTIONS: Record<WhisperApiKind, { label: string }> = {
  asr_webservice: { label: "Whisper ASR webservice (fog's Whisper app)" },
  openai: { label: "OpenAI-compatible (/v1/audio/transcriptions)" },
};
