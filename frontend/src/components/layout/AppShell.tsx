import { Suspense, useEffect, useState } from "react";
import { Link, NavLink, Outlet, useLocation } from "react-router-dom";
import { Activity, BarChart3, Bell, Download, LibraryBig, ListVideo, Rss, FileQuestion, Gauge, Home as HomeIcon, RadioTower, Tv, LogOut, Menu as MenuIcon, Moon, PanelLeftClose, PanelLeftOpen, Search, Settings as SettingsIcon, Sun, X } from "lucide-react";
import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { LIBRARY_KIND_ICONS } from "@/lib/libraries";
import { keys } from "@/lib/queryKeys";
import { baseballQuery, basketballQuery, librariesQuery } from "@/lib/queries";
import { useAuth } from "@/hooks/useAuth";
import { useCatalogVersion } from "@/hooks/useCatalogVersion";
import { BREAKPOINTS, useMediaQuery } from "@/hooks/useMediaQuery";
import { useTheme } from "@/hooks/useTheme";
import { useSidebarCollapsed } from "@/hooks/useSidebarCollapsed";
import { cn } from "@/lib/cn";
import { Button } from "@/components/ui/Button";
import { RouteErrorBoundary } from "@/components/layout/RouteErrorBoundary";
import { LoadingState } from "@/components/ui/PageState";
import { CommandPalette } from "@/components/layout/CommandPalette";
import { ProfileAvatar } from "@/components/profiles/ProfileAvatar";
import { useProfile } from "@/hooks/useProfile";
import { TV_KEY } from "@/lib/tv";
import type { NotificationsResponse } from "@/types";
import { IconButton } from "@/components/ui/IconButton";
import { offlineSupported } from "@/lib/offline/downloads";
import { BrandMark } from "@/components/layout/BrandMark";
import { BaseballIcon } from "@/components/baseball/BaseballIcon";
import { BasketballIcon } from "@/components/basketball/BasketballIcon";
import { SidebarCollapsed, SidebarLink, SidebarNav, type SidebarItem } from "@/components/layout/SidebarNav";

/** How often the bell re-asks for the unread count. */
const UNREAD_POLL_MS = 120_000;

const HOME = { key: "home", to: "/", label: "Home", icon: HomeIcon, end: true } as const;

const NAV = [
  { key: "live", to: "/live", label: "Grid", icon: RadioTower, end: false },
  // Only once the household has an MLB.tv account (Settings › Integrations).
  { key: "baseball", to: "/baseball", label: "Baseball", icon: BaseballIcon, end: false, baseball: true },
  // Only once the household turns on NBA League Pass (Settings › Integrations).
  { key: "basketball", to: "/basketball", label: "Basketball", icon: BasketballIcon, end: false, basketball: true },
  { key: "subscriptions", to: "/subscriptions", label: "Subscriptions", icon: Rss, end: false },
  { key: "collections", to: "/collections", label: "Collections", icon: LibraryBig, end: false },
  { key: "playlists", to: "/playlists", label: "Playlists", icon: ListVideo, end: false },
  { key: "downloads", to: "/downloads", label: "Downloads", icon: Download, end: false, offline: true },
  { key: "needs_match", to: "/needs-match", label: "Needs match", icon: FileQuestion, end: false, grownUps: true },
  { key: "stats", to: "/stats", label: "Stats", icon: BarChart3, end: false, admin: true, grownUps: true },
  { key: "playback", to: "/playback", label: "Playback", icon: Gauge, end: false, admin: true, grownUps: true },
  { key: "activity", to: "/activity", label: "Activity", icon: Activity, end: false, grownUps: true },
  { key: "settings", to: "/settings", label: "Settings", icon: SettingsIcon, end: false, grownUps: true },
] as const;

/**
 * The app frame. Phase 0 keeps hook's sidebar; the cinematic home and the
 * player's full-bleed layout replace it for viewing routes in Phase 1. On a wide screen the navigation is a sidebar that is
 * always there; below `lg` it folds into a drawer behind a top bar, so the
 * page gets the whole width of a phone. One `<aside>` serves both — the
 * drawer is the same element positioned off-canvas — so the nav exists once
 * in the DOM and the active link, badge and sign-out never drift apart.
 * The desktop sidebar can also fold down to a rail of icons, for a page
 * that wants the width; the drawer is always full.
 */
export function AppShell() {
  const { user, signOut } = useAuth();
  const { profile, switchProfile } = useProfile();
  const kid = profile?.kind === "kid";
  // Back on the desktop layout: the player's Back comes here again.
  useEffect(() => {
    try {
      sessionStorage.removeItem(TV_KEY);
    } catch {
      // A nicety.
    }
  }, []);
  const { theme, toggle } = useTheme();
  const { pathname } = useLocation();
  const wide = useMediaQuery(BREAKPOINTS.lg);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const sidebar = useSidebarCollapsed();
  const collapsed = wide && sidebar.collapsed;
  const [paletteOpen, setPaletteOpen] = useState(false);
  const mac = typeof navigator !== "undefined" && /Mac|iPhone|iPad/.test(navigator.platform);

  // The bell's page is not in NAV (it lives on the bell), but it still names
  // the tab.
  const sectionLabel =
    [HOME, ...NAV].find(({ to, end }) => (end ? pathname === to : pathname.startsWith(to)))?.label ??
    (pathname.startsWith("/notifications") ? "Notifications" : undefined);
  useEffect(() => {
    document.title = sectionLabel ? `Stream › ${sectionLabel}` : "Stream";
  }, [sectionLabel]);

  // Navigating is how a drawer gets used, so navigating closes it; so does
  // growing past the breakpoint, or the drawer would be "open" invisibly and
  // pop back the next time the window shrinks.
  useEffect(() => setDrawerOpen(false), [pathname]);
  useEffect(() => {
    if (wide) setDrawerOpen(false);
  }, [wide]);
  useEffect(() => {
    if (!drawerOpen) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") setDrawerOpen(false);
    };
    document.addEventListener("keydown", onKeyDown);
    // Keep the page behind the drawer still — on a phone, a scrolling
    // backdrop reads as the drawer having not really opened.
    const { overflow } = document.body.style;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKeyDown);
      document.body.style.overflow = overflow;
    };
  }, [drawerOpen]);

  // What Hook or Sonarr just delivered shows up without a reload.
  useCatalogVersion();

  // The bell needs the count, not the rows — per=1 keeps the answer small.
  const { data: unreadCount } = useQuery({
    queryKey: keys.notifications.unreadCount(),
    queryFn: ({ signal }) => api.get<NotificationsResponse>("/notifications?per=1", { signal }),
    select: (response) => response.unread_count,
    refetchInterval: UNREAD_POLL_MS,
  });
  const unread = unreadCount ?? 0;

  // Each library is a destination of its own, the way Plex lists them.
  const { data: libraries, isPending: librariesPending } = useQuery(librariesQuery());
  const baseball = useQuery(baseballQuery());
  const basketball = useQuery(basketballQuery());
  const navItems: SidebarItem[] = [
    ...(libraries ?? []).map((library) => ({
      key: `library:${library.id}`,
      to: `/library/${library.id}`,
      label: library.name,
      icon: LIBRARY_KIND_ICONS[library.kind],
      end: false,
      library,
    })),
    // A kid profile gets the watching, not the running (PROPOSAL §7.4).
    ...NAV.filter(
      (item) =>
        (!("admin" in item) || user?.role === "admin") &&
        !(kid && "grownUps" in item) &&
        (!("offline" in item) || offlineSupported()) &&
        (!("baseball" in item) || baseball.data?.available === true) &&
        (!("basketball" in item) || basketball.data?.available === true),
    ),
  ];

  const bell = (
    <NavLink
      to="/notifications"
      aria-label={`Notifications, ${unread} unread`}
      title={`${unread} unread`}
      className={({ isActive }) =>
        cn(
          "relative inline-flex items-center gap-1 rounded-[var(--radius-control)] p-1.5",
          isActive ? "bg-primary/10 text-primary" : "text-muted hover:bg-surface-raised hover:text-foreground",
        )
      }
    >
      <Bell className="h-4 w-4" aria-hidden />
      {unread > 0 ? (
        <span className="rounded-full bg-primary px-1.5 text-[10px] font-semibold tabular-nums text-primary-foreground">{unread}</span>
      ) : null}
    </NavLink>
  );

  const pairLink = kid ? null : (
    <NavLink
      to="/pair"
      aria-label="Sign in a TV"
      title="Sign in a TV"
      className={({ isActive }) =>
        cn(
          "inline-flex items-center rounded-[var(--radius-control)] p-1.5",
          isActive ? "bg-primary/10 text-primary" : "text-muted hover:bg-surface-raised hover:text-foreground",
        )
      }
    >
      <Tv className="h-4 w-4" aria-hidden />
    </NavLink>
  );

  return (
    <div className="flex min-h-dvh">
      {drawerOpen ? (
        <button
          type="button"
          aria-label="Close navigation"
          onClick={() => setDrawerOpen(false)}
          className="fixed inset-0 z-30 bg-foreground/40 lg:hidden"
        />
      ) : null}

      <aside
        id="app-navigation"
        aria-label="Navigation"
        data-overlay={drawerOpen ? "" : undefined}
        className={cn(
          "flex h-dvh w-64 shrink-0 flex-col border-r border-border bg-surface",
          // Desktop: in the flow, stuck to the top. Mobile: an off-canvas
          // panel that slides in; `hidden` keeps it out of the tab order
          // and the accessibility tree while it is closed.
          "lg:sticky lg:top-0 lg:flex lg:translate-x-0",
          collapsed ? "lg:w-16" : "lg:w-60",
          drawerOpen ? "fixed inset-y-0 left-0 z-40 shadow-xl" : "hidden",
        )}
      >
        {collapsed ? (
          <div className="flex flex-col items-center gap-2 py-4">
            <Link to="/" aria-label="Stream home" title="Home" className="rounded-[var(--radius-control)]">
              <BrandMark />
            </Link>
            <IconButton label="Expand sidebar" title="Expand sidebar" aria-expanded={false} aria-controls="app-navigation" onClick={sidebar.toggle}>
              <PanelLeftOpen className="h-4 w-4" aria-hidden />
            </IconButton>
          </div>
        ) : (
          <div className="flex items-start justify-between px-5 py-4">
            <Link to="/" title="Home" className="flex items-center gap-2.5 rounded-[var(--radius-control)]">
              <BrandMark className="h-9 w-9" />
              <div>
                <p className="text-sm font-semibold text-foreground">Stream</p>
                <p className="text-xs text-muted">home video player</p>
              </div>
            </Link>
            <IconButton label="Close navigation" size="lg" onClick={() => setDrawerOpen(false)} className="-mr-2 -mt-1 p-2 lg:hidden">
              <X className="h-5 w-5" aria-hidden />
            </IconButton>
            <IconButton
              label="Collapse sidebar"
              title="Collapse sidebar"
              aria-expanded
              aria-controls="app-navigation"
              onClick={sidebar.toggle}
              className="-mr-2 hidden lg:inline-flex"
            >
              <PanelLeftClose className="h-4 w-4" aria-hidden />
            </IconButton>
          </div>
        )}

        <div className={cn("pb-3", collapsed ? "flex justify-center" : "px-3")}>
          {collapsed ? (
            <IconButton label="Search" title={`Search (${mac ? "⌘K" : "Ctrl K"})`} onClick={() => setPaletteOpen(true)} className="p-2">
              <Search className="h-4 w-4" aria-hidden />
            </IconButton>
          ) : (
            <button
              type="button"
              onClick={() => setPaletteOpen(true)}
              className="flex w-full items-center gap-2.5 rounded-[var(--radius-control)] border border-border bg-surface-raised px-3 py-2 text-sm text-muted hover:text-foreground"
            >
              <Search className="h-4 w-4" aria-hidden />
              <span className="flex-1 text-left">Search</span>
              <kbd className="text-xs">{mac ? "⌘K" : "Ctrl K"}</kbd>
            </button>
          )}
        </div>

        <SidebarCollapsed.Provider value={collapsed}>
          <nav className={cn("flex-1 space-y-0.5 overflow-y-auto", collapsed ? "px-2" : "px-3")}>
            <SidebarLink item={HOME} />
            <SidebarNav items={navItems} loading={librariesPending || baseball.isPending || basketball.isPending} />
          </nav>
        </SidebarCollapsed.Provider>

        {collapsed ? (
          <div className="flex flex-col items-center gap-1 border-t border-border py-3">
            {profile ? (
              <button
                type="button"
                onClick={switchProfile}
                title={`${profile.name} — switch profile`}
                aria-label="Switch profile"
                className="rounded-full p-1 hover:bg-surface-raised"
              >
                <ProfileAvatar profile={profile} size="sm" />
              </button>
            ) : null}
            <IconButton label="Toggle theme" title="Toggle theme" onClick={toggle}>
              {theme === "dark" ? <Sun className="h-4 w-4" aria-hidden /> : <Moon className="h-4 w-4" aria-hidden />}
            </IconButton>
            {bell}
            {pairLink}
            <IconButton label="Sign out" title="Sign out" onClick={signOut}>
              <LogOut className="h-4 w-4" aria-hidden />
            </IconButton>
          </div>
        ) : (
          <div className="border-t border-border px-3 py-3 pb-[max(0.75rem,env(safe-area-inset-bottom))]">
            {profile ? (
              <button
                type="button"
                onClick={switchProfile}
                title="Switch profile"
                className="mb-1 flex w-full items-center gap-2.5 rounded-[var(--radius-control)] px-2 py-1.5 text-left hover:bg-surface-raised"
              >
                <ProfileAvatar profile={profile} size="sm" />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm font-medium text-foreground">{profile.name}</span>
                  <span className="block text-xs text-muted">Switch profile</span>
                </span>
              </button>
            ) : null}
            <div className="flex items-center justify-between gap-2 px-2 py-1.5">
              <div className="min-w-0">
                <p className="truncate text-sm text-foreground">{user?.name}</p>
                <p className="truncate text-xs text-muted">{user?.role}</p>
              </div>
              <div className="flex items-center gap-1">
                <IconButton label="Toggle theme" onClick={toggle}>
                  {theme === "dark" ? <Sun className="h-4 w-4" aria-hidden /> : <Moon className="h-4 w-4" aria-hidden />}
                </IconButton>
                {pairLink}
                {bell}
              </div>
            </div>
            <Button variant="ghost" size="sm" className="mt-1 w-full justify-start" onClick={signOut}>
              <LogOut className="h-4 w-4" aria-hidden />
              Sign out
            </Button>
          </div>
        )}
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="sticky top-0 z-20 flex h-14 items-center gap-1 border-b border-border bg-surface/95 px-2 backdrop-blur lg:hidden">
          <IconButton
            label="Open navigation"
            size="lg"
            onClick={() => setDrawerOpen(true)}
            aria-expanded={drawerOpen}
            aria-controls="app-navigation"
            className="text-foreground"
          >
            <MenuIcon className="h-5 w-5" aria-hidden />
          </IconButton>
          <p className="flex min-w-0 flex-1 items-center gap-1 truncate text-sm font-semibold text-foreground">
            <Link to="/" title="Home" className="flex shrink-0 items-center gap-1 rounded-[var(--radius-control)]">
              <BrandMark className="h-6 w-6" />
              Stream
            </Link>
            {sectionLabel ? <span className="truncate font-normal text-muted">› {sectionLabel}</span> : null}
          </p>
          <IconButton label="Search" size="lg" onClick={() => setPaletteOpen(true)} className="text-foreground">
            <Search className="h-5 w-5" aria-hidden />
          </IconButton>
          {bell}
        </header>

        <main className="min-w-0 flex-1">
          <RouteErrorBoundary>
            <Suspense fallback={<LoadingState />}>
              <Outlet />
            </Suspense>
          </RouteErrorBoundary>
        </main>
      </div>
      <CommandPalette open={paletteOpen} onOpenChange={setPaletteOpen} />
    </div>
  );
}
