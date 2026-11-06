import type { HealthTone } from "@/components/ui/HealthCard";
import type { HealthCheck, HealthStatus } from "@/types";

export const HEALTH_STATUS_LABELS: Record<HealthStatus, string> = {
  ok: "OK",
  watch: "Keep an eye on",
  act: "Do something",
};

export const HEALTH_STATUS_TONES: Record<HealthStatus, HealthTone> = {
  ok: "positive",
  watch: "warning",
  act: "danger",
};

/**
 * Where a health check's card goes: the Playback page with the check's tab
 * and filters in the URL, as the tables read them (arrays as repeated keys,
 * a direction as `dir`).
 */
export function healthLink(link: HealthCheck["link"]): string {
  if ("path" in link && typeof link.path === "string") return link.path;
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(link)) {
    const name = key === "direction" ? "dir" : key;
    if (Array.isArray(value)) value.forEach((each) => params.append(name, String(each)));
    else params.set(name, String(value));
  }
  return `/playback?${params.toString()}`;
}
