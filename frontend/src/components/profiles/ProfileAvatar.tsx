import { cn } from "@/lib/cn";
import type { ProfileInfo } from "@/types";

const SIZES = { sm: "h-7 w-7 text-sm", md: "h-10 w-10 text-lg", lg: "h-24 w-24 text-4xl sm:h-28 sm:w-28" } as const;

/**
 * A profile's face: its emoji, or its initial, on its colour. The colour is
 * the profile's own data (chosen in Settings), not a theme colour.
 */
export function ProfileAvatar({ profile, size = "md", className }: { profile: Pick<ProfileInfo, "name" | "color" | "avatar">; size?: keyof typeof SIZES; className?: string }) {
  return (
    <span
      aria-hidden
      className={cn("inline-flex shrink-0 select-none items-center justify-center rounded-[var(--radius-card)] font-semibold text-background", SIZES[size], className)}
      style={{ backgroundColor: profile.color }}
    >
      {profile.avatar ?? profile.name.slice(0, 1).toUpperCase()}
    </span>
  );
}
