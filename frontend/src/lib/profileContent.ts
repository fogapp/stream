import type { ProfileContentItem } from "@/types";

/** What a hidden or tagged title is, as Settings › Profiles names it. */
export const PROFILE_CONTENT_KIND_LABELS: Record<ProfileContentItem["kind"], string> = {
  movie: "Movie",
  show: "Show",
  channel: "YouTube channel",
  album: "Album",
};
