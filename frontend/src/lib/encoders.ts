import type { EncoderKind } from "@/types";

export const ENCODER_LABELS: Record<EncoderKind, string> = {
  software: "CPU (software)",
  vaapi: "Intel iGPU (VA-API)",
  videotoolbox: "Apple VideoToolbox",
};
