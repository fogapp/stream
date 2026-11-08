// Profiles (profile_serializer, profile_content_serializer).

import type { ImageInfo } from "@/types/catalog";

/** Profile::Kind: a kid profile has no settings, admin pages or activity. */
export const PROFILE_KINDS = ["standard", "kid"] as const;

export type ProfileKind = (typeof PROFILE_KINDS)[number];

export interface ProfileInfo {
  id: string;
  name: string;
  color: string;
  /** An emoji, or null for the name's initial. */
  avatar: string | null;
  has_pin: boolean;
  kind: ProfileKind;
  max_rating_age: number | null;
  allow_unrated: boolean;
  library_ids: string[];
  curated: boolean;
  up_next_seconds: number | null;
  always_skip_intro: boolean;
  always_skip_credits: boolean;
  still_watching_after: number | null;
  /** A video starts as its page opens, replacing what's playing (muted if the browser insists). */
  autoplay_videos: boolean;
}

/** What a profile can hide from itself (ProfileExclusion::EXCLUDABLE). */
export const HIDEABLE_KINDS = ["movie", "show", "channel"] as const;

export type HideableKind = (typeof HIDEABLE_KINDS)[number];

/** A title a profile's own configuration names (ProfileContentSerializer). */
export interface ProfileContentItem {
  kind: HideableKind | "album";
  id: string;
  title: string;
  /** A film's or show's year, a channel's handle. */
  detail: string | null;
  image: ImageInfo | null;
}

/** GET /profiles/:id/content: hidden from it, and (admins only) tagged for it. */
export interface ProfileContent {
  hidden: ProfileContentItem[];
  tagged?: ProfileContentItem[];
}
