import { useEffect, useRef, type ReactNode } from "react";
import { Link, useLocation, useNavigate } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { Monitor, Search } from "lucide-react";
import { librariesQuery } from "@/lib/queries";
import { TV_KEY } from "@/lib/tv";
import { isTypingTarget } from "@/lib/keys";
import { useProfile } from "@/hooks/useProfile";
import { useSpatialNav } from "@/hooks/useSpatialNav";
import { useCatalogVersion } from "@/hooks/useCatalogVersion";
import { ProfileAvatar } from "@/components/profiles/ProfileAvatar";
import { BrandMark } from "@/components/layout/BrandMark";

/**
 * The 10-foot layout (PROPOSAL §7.4): dark, large, one thing focused at a
 * time, driven by a remote's arrows, OK and Back.
 */
export function TvShell({ children, ready = true }: { children: ReactNode; ready?: boolean }) {
  const root = useRef<HTMLDivElement>(null);
  const navigate = useNavigate();
  const { pathname } = useLocation();
  const { profile, switchProfile } = useProfile();
  // Every library has a place of its own on the TV.
  const libraries = useQuery(librariesQuery());
  const browsable = libraries.data ?? [];
  useSpatialNav(root, ready);
  useCatalogVersion();

  // The player's Back comes home to these pages, not the desktop ones.
  useEffect(() => {
    try {
      sessionStorage.setItem(TV_KEY, "1");
    } catch {
      // A nicety.
    }
  }, []);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if ((event.key === "Backspace" || event.key === "Escape" || event.key === "BrowserBack") && pathname !== "/tv") {
        if (isTypingTarget(event.target)) return;
        event.preventDefault();
        navigate(-1);
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [navigate, pathname]);

  return (
    <div ref={root} data-theme="dark" className="min-h-dvh bg-background text-foreground [&_[data-tv]:focus-visible]:outline-none [&_[data-tv]:focus]:ring-4 [&_[data-tv]:focus]:ring-primary">
      <header className="flex items-center justify-between px-12 pt-8">
        <nav aria-label="TV" className="flex items-center gap-2">
          <Link to="/tv" data-tv className="flex items-center gap-3 rounded-[var(--radius-control)] px-2 text-2xl font-bold tracking-tight">
            <BrandMark className="h-10 w-10" />
            Stream
          </Link>
          <Link to="/tv/live" data-tv className="rounded-[var(--radius-control)] px-3 py-1 text-xl text-muted focus:text-foreground">
            Grid
          </Link>
          {browsable.map((library) => (
            <Link key={library.id} to={`/tv/library/${library.id}`} data-tv className="rounded-[var(--radius-control)] px-3 py-1 text-xl text-muted focus:text-foreground">
              {library.name}
            </Link>
          ))}
          <Link to="/tv/search" data-tv aria-label="Search" className="rounded-[var(--radius-control)] p-2 text-muted focus:text-foreground">
            <Search className="h-7 w-7" aria-hidden />
          </Link>
        </nav>
        <div className="flex items-center gap-4">
          <Link to="/" data-tv title="Leave the TV layout" aria-label="Leave the TV layout" className="rounded-[var(--radius-control)] p-2 text-muted">
            <Monitor className="h-7 w-7" aria-hidden />
          </Link>
          {profile ? (
            <button type="button" data-tv onClick={switchProfile} className="flex items-center gap-3 rounded-[var(--radius-card)] p-1 pr-3 text-lg">
              <ProfileAvatar profile={profile} size="md" />
              {profile.name}
            </button>
          ) : null}
        </div>
      </header>
      <main className="pb-16">{children}</main>
    </div>
  );
}
