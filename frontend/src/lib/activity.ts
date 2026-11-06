import type { BadgeTone } from "@/components/ui/Badge";
import type { ActivitySeverity } from "@/types";

export const ACTIVITY_SEVERITY_TONES: Record<ActivitySeverity, BadgeTone> = {
  info: "neutral",
  warn: "warning",
  error: "danger",
};
