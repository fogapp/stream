import type { ComponentType } from "react";
import { Activity, BarChart3, Bell, Download, FileQuestion, Gauge, Home as HomeIcon, LibraryBig, ListVideo, RadioTower, Rss, Settings as SettingsIcon } from "lucide-react";
import { BaseballIcon } from "@/components/baseball/BaseballIcon";
import { BasketballIcon } from "@/components/basketball/BasketballIcon";
import type { ProfileKind, UserRole } from "@/types";

/** What a destination waits on before it's offered. */
export const NAV_FEATURES = ["baseball", "basketball", "offline"] as const;

export type NavFeature = (typeof NAV_FEATURES)[number];

export type NavFeatures = Record<NavFeature, boolean>;

export interface NavEntry {
  /** What the profile's sidebar arrangement calls it. */
  key: string;
  to: string;
  label: string;
  icon: ComponentType<{ className?: string; "aria-hidden"?: boolean }>;
  /** Active only on exactly `to` (Home), not on everything under it. */
  end: boolean;
  /** Admins only. */
  admin?: boolean;
  /** Not for a kid profile: it gets the watching, not the running (PROPOSAL §7.4). */
  grownUps?: boolean;
  /** Offered only once this is on. */
  feature?: NavFeature;
  /** Left out of the sidebar's list (it has its own place in the frame). */
  sidebar?: false;
  /** What ⌘K calls it, where that says more than the sidebar has room for. */
  paletteLabel?: string;
}

export const HOME_NAV: NavEntry = { key: "home", to: "/", label: "Home", icon: HomeIcon, end: true };

/**
 * Every destination below Home and the libraries, in the sidebar's default
 * order: the sidebar and ⌘K both read this, so they offer the same places.
 */
export const NAV: readonly NavEntry[] = [
  { key: "live", to: "/live", label: "Grid", icon: RadioTower, end: false },
  // Once the household has an MLB.tv account (Settings › Integrations).
  { key: "baseball", to: "/baseball", label: "Baseball", icon: BaseballIcon, end: false, feature: "baseball" },
  // Once the household turns on NBA League Pass (Settings › Integrations).
  { key: "basketball", to: "/basketball", label: "Basketball", icon: BasketballIcon, end: false, feature: "basketball" },
  { key: "subscriptions", to: "/subscriptions", label: "Subscriptions", icon: Rss, end: false },
  { key: "collections", to: "/collections", label: "Collections", icon: LibraryBig, end: false },
  { key: "playlists", to: "/playlists", label: "Playlists", icon: ListVideo, end: false },
  // Where this browser can keep a download.
  { key: "downloads", to: "/downloads", label: "Downloads", icon: Download, end: false, feature: "offline" },
  { key: "needs_match", to: "/needs-match", label: "Needs match", icon: FileQuestion, end: false, grownUps: true },
  { key: "stats", to: "/stats", label: "Stats", icon: BarChart3, end: false, admin: true, grownUps: true },
  { key: "playback", to: "/playback", label: "Playback", icon: Gauge, end: false, admin: true, grownUps: true, paletteLabel: "Playback decisions" },
  { key: "activity", to: "/activity", label: "Activity", icon: Activity, end: false, grownUps: true },
  // The bell, in the frame.
  { key: "notifications", to: "/notifications", label: "Notifications", icon: Bell, end: false, sidebar: false },
  { key: "settings", to: "/settings", label: "Settings", icon: SettingsIcon, end: false, grownUps: true },
];

/** The destinations this user, on this profile, is offered. */
export function visibleNav(
  user: { role: UserRole } | null | undefined,
  profile: { kind: ProfileKind } | null | undefined,
  features: NavFeatures,
): NavEntry[] {
  const kid = profile?.kind === "kid";
  return NAV.filter(
    (entry) => (!entry.admin || user?.role === "admin") && !(kid && entry.grownUps) && (!entry.feature || features[entry.feature]),
  );
}

/** The destination a path is under, for the page title. */
export function navFor(pathname: string): NavEntry | undefined {
  return [HOME_NAV, ...NAV].find(({ to, end }) => (end ? pathname === to : pathname.startsWith(to)));
}
