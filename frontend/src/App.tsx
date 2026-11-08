import { lazy, Suspense, useEffect, type ReactElement } from "react";
import { QueryCache, QueryClient, QueryClientProvider, MutationCache } from "@tanstack/react-query";
import { BrowserRouter, Navigate, Route, Routes, useLocation } from "react-router-dom";
import { ApiError } from "@/api/client";
import { toast, Toasts } from "@/components/ui/Toast";
import { AuthProvider, clearSession, useAuth } from "@/hooks/useAuth";
import { PlaybackProvider } from "@/hooks/usePlayback";
import { ProfileProvider, useProfile } from "@/hooks/useProfile";
import { AppShell } from "@/components/layout/AppShell";
import { Home } from "@/pages/Home";
import { Library } from "@/pages/Library";
import { MovieDetail } from "@/pages/MovieDetail";
import { Notifications } from "@/pages/Notifications";
import { ShowDetail } from "@/pages/ShowDetail";
import { PersonDetail } from "@/pages/PersonDetail";
import { Collections } from "@/pages/Collections";
import { CollectionDetail } from "@/pages/CollectionDetail";
import { Playlists } from "@/pages/Playlists";
import { PlaylistDetail } from "@/pages/PlaylistDetail";
import { ChannelDetail } from "@/pages/ChannelDetail";
import { VideoDetail } from "@/pages/VideoDetail";
import { Subscriptions } from "@/pages/Subscriptions";
import { ClipDetail } from "@/pages/ClipDetail";
import { Watch } from "@/pages/Watch";
import { Downloads, OfflineDownloads } from "@/pages/Downloads";
import { OfflineWatch } from "@/pages/OfflineWatch";
import { RemoteListener } from "@/components/remote/RemoteListener";
import { registerServiceWorker, syncPositions } from "@/lib/offline/downloads";
import { RouteErrorBoundary } from "@/components/layout/RouteErrorBoundary";
import { LoadingState } from "@/components/ui/PageState";

// The admin pages and the TV layout load when they're opened: most visits
// (and every kid profile) never need them. So do the Grid and live streams,
// and signing in (with its passkey library): a signed-in visit never needs that.
// Downloads stay in the first load — they play with no network to fetch a page.
// (Live and Pair wait in the shell's own Suspense, as Settings does.)
const Login = lazy(() => import("@/pages/Login").then((module) => ({ default: module.Login })));
const SigninComplete = lazy(() => import("@/pages/SigninHandoff").then((module) => ({ default: module.SigninComplete })));
const SigninLink = lazy(() => import("@/pages/SigninHandoff").then((module) => ({ default: module.SigninLink })));
const Pair = lazy(() => import("@/pages/Pair").then((module) => ({ default: module.Pair })));
const Live = lazy(() => import("@/pages/Live").then((module) => ({ default: module.Live })));
const LiveWatch = lazy(() => import("@/pages/LiveWatch").then((module) => ({ default: module.LiveWatch })));
const StreamWatch = lazy(() => import("@/pages/StreamWatch").then((module) => ({ default: module.StreamWatch })));
const ActivityLog = lazy(() => import("@/pages/ActivityLog").then((module) => ({ default: module.ActivityLog })));
const FileDetail = lazy(() => import("@/pages/FileDetail").then((module) => ({ default: module.FileDetail })));
const NeedsMatch = lazy(() => import("@/pages/NeedsMatch").then((module) => ({ default: module.NeedsMatch })));
const PlaybackDecisions = lazy(() => import("@/pages/PlaybackDecisions").then((module) => ({ default: module.PlaybackDecisions })));
const Settings = lazy(() => import("@/pages/Settings").then((module) => ({ default: module.Settings })));
const Stats = lazy(() => import("@/pages/Stats").then((module) => ({ default: module.Stats })));
const Baseball = lazy(() => import("@/pages/Baseball").then((module) => ({ default: module.Baseball })));
const Basketball = lazy(() => import("@/pages/Basketball").then((module) => ({ default: module.Basketball })));
const LiveChannels = lazy(() => import("@/pages/LiveChannels").then((module) => ({ default: module.LiveChannels })));
const LiveChannelEdit = lazy(() => import("@/pages/LiveChannelEdit").then((module) => ({ default: module.LiveChannelEdit })));
const TvHome = lazy(() => import("@/pages/tv/TvHome").then((module) => ({ default: module.TvHome })));
const TvPair = lazy(() => import("@/pages/tv/TvPair").then((module) => ({ default: module.TvPair })));
const TvTitle = lazy(() => import("@/pages/tv/TvTitle").then((module) => ({ default: module.TvTitle })));
const TvSearch = lazy(() => import("@/pages/tv/TvSearch").then((module) => ({ default: module.TvSearch })));
const TvLibrary = lazy(() => import("@/pages/tv/TvLibrary").then((module) => ({ default: module.TvLibrary })));
const TvChannel = lazy(() => import("@/pages/tv/TvLibraryKinds").then((module) => ({ default: module.TvChannel })));
const TvLive = lazy(() => import("@/pages/tv/TvLive").then((module) => ({ default: module.TvLive })));

/**
 * A page outside the shell that loads when opened: its own boundary and
 * wait. A full-screen one (`screen`, the wait's words) waits as it will
 * load, dark over the whole window.
 */
function Deferred({ children, screen }: { children: ReactElement; screen?: string }) {
  const fallback = screen ? (
    <div data-theme="dark" className="fixed inset-0 z-50 flex items-center justify-center bg-background">
      <LoadingState label={screen} />
    </div>
  ) : (
    <LoadingState />
  );
  return (
    <RouteErrorBoundary>
      <Suspense fallback={fallback}>{children}</Suspense>
    </RouteErrorBoundary>
  );
}

/** A 401 anywhere means the token is gone or revoked — clear and bounce to
 *  login rather than leaving the app half-authenticated. */
function handleUnauthorized(error: unknown) {
  if (error instanceof ApiError && error.status === 401) {
    clearSession();
    if (window.location.pathname !== "/login") window.location.href = "/login";
  }
}

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      // No retries on any 4xx: a 403/404/422 is deterministic — retrying
      // just multiplies backend load and delays the ErrorState.
      retry: (failureCount, error) =>
        error instanceof ApiError && error.status >= 400 && error.status < 500
          ? false
          : failureCount < 2,
    },
  },
  queryCache: new QueryCache({ onError: handleUnauthorized }),
  mutationCache: new MutationCache({
    onError: (error, _variables, _context, mutation) => {
      handleUnauthorized(error);
      if (error instanceof ApiError && error.status === 401) return;
      // A mutation that declares its own onError owns its error UI (the
      // forms with inline messages). Everything else gets the shared toast —
      // a silently failed mutation refetches the unchanged value and reads
      // as a no-op, and "silent failure is the enemy" applies here too.
      if (mutation.options.onError) return;
      toast.error(error instanceof ApiError ? error.message : "That didn't go through.");
    },
  }),
});

function ProtectedRoutes() {
  const { isAuthenticated } = useAuth();
  const { pathname, search } = useLocation();
  // A TV signs in with a code, not a keyboard. Anywhere else comes back
  // after login — a TV's QR code lands on /pair?code=… signed out.
  if (!isAuthenticated) {
    if (pathname.startsWith("/tv")) return <Navigate to="/tv/pair" replace />;
    return <Navigate to="/login" state={{ from: pathname + search }} replace />;
  }

  return (
    <ProfileProvider>
      <ProfileRoutes />
    </ProfileProvider>
  );
}

/** Keyed by profile: switching closes whatever the last one was playing. */
function ProfileRoutes() {
  const { profile } = useProfile();
  const kid = profile?.kind === "kid";
  const grownUps = (element: ReactElement) => (kid ? <Navigate to="/" replace /> : element);
  return (
    <PlaybackProvider key={profile?.id}>
      <RemoteListener />
      <Routes>
      {/* The player takes the whole screen: no shell around it. */}
      <Route path="watch/:kind/:id" element={<Watch />} />
      <Route path="live/:number" element={<Deferred screen="Tuning…"><LiveWatch /></Deferred>} />
      <Route path="stream/:id" element={<Deferred screen="Connecting…"><StreamWatch /></Deferred>} />
      {/* The 10-foot layout for a TV browser. */}
      <Route path="tv" element={<Deferred><TvHome /></Deferred>} />
      <Route path="tv/movie/:id" element={<Deferred><TvTitle kind="movie" /></Deferred>} />
      <Route path="tv/show/:id" element={<Deferred><TvTitle kind="show" /></Deferred>} />
      <Route path="tv/search" element={<Deferred><TvSearch /></Deferred>} />
      <Route path="tv/live" element={<Deferred><TvLive /></Deferred>} />
      <Route path="tv/library/:id" element={<Deferred><TvLibrary /></Deferred>} />
      <Route path="tv/channel/:id" element={<Deferred><TvChannel /></Deferred>} />
      <Route element={<AppShell />}>
        <Route index element={<Home />} />
        <Route path="library/:id" element={<Library />} />
        <Route path="movie/:id" element={<MovieDetail />} />
        <Route path="show/:id" element={<ShowDetail />} />
        <Route path="person/:id" element={<PersonDetail />} />
        <Route path="collections" element={<Collections />} />
        <Route path="live" element={<Live />} />
        <Route path="live/channels" element={grownUps(<LiveChannels />)} />
        <Route path="live/channels/:id" element={grownUps(<LiveChannelEdit />)} />
        <Route path="channel/:id" element={<ChannelDetail />} />
        <Route path="subscriptions" element={<Subscriptions />} />
        <Route path="baseball" element={<Deferred><Baseball /></Deferred>} />
        <Route path="basketball" element={<Deferred><Basketball /></Deferred>} />
        <Route path="pair" element={<Pair />} />
        <Route path="clip/:id" element={<ClipDetail />} />
        <Route path="video/:id" element={<VideoDetail />} />
        <Route path="playlists" element={<Playlists />} />
        <Route path="playlist/:id" element={<PlaylistDetail />} />
        <Route path="collection/:id" element={<CollectionDetail />} />
        <Route path="settings" element={grownUps(<Settings />)} />
        <Route path="activity" element={grownUps(<ActivityLog />)} />
        <Route path="stats" element={grownUps(<Stats />)} />
        <Route path="needs-match" element={grownUps(<NeedsMatch />)} />
        <Route path="playback" element={grownUps(<PlaybackDecisions />)} />
        <Route path="files/:id" element={grownUps(<FileDetail />)} />
        <Route path="notifications" element={<Notifications />} />
        <Route path="downloads" element={<Downloads />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
      </Routes>
    </PlaybackProvider>
  );
}

/** Downloads play with no network, so they don't wait on the server's profile. */
function OfflineRoute({ children }: { children: ReactElement }) {
  const { isAuthenticated } = useAuth();
  return isAuthenticated ? children : <Navigate to="/login" replace />;
}

export function App() {
  useEffect(() => {
    registerServiceWorker();
    // What was watched offline, told to the server when there's one to tell.
    void syncPositions();
    const sync = () => void syncPositions();
    window.addEventListener("online", sync);
    return () => window.removeEventListener("online", sync);
  }, []);

  return (
    <QueryClientProvider client={queryClient}>
      <AuthProvider>
        <BrowserRouter>
          <Routes>
            <Route path="/login" element={<Deferred><Login /></Deferred>} />
            {/* Sign in with fog: where its callback hands the browser back. */}
            <Route path="/auth/complete" element={<Deferred><SigninComplete /></Deferred>} />
            <Route path="/auth/link" element={<Deferred><SigninLink /></Deferred>} />
            <Route path="/tv/pair" element={<Deferred><TvPair /></Deferred>} />
            <Route path="/offline" element={<OfflineRoute><OfflineDownloads /></OfflineRoute>} />
            <Route path="/downloads/:id" element={<OfflineRoute><OfflineWatch /></OfflineRoute>} />
            <Route path="/*" element={<ProtectedRoutes />} />
          </Routes>
        </BrowserRouter>
        {/* Above the routes: the full-screen players are outside the app shell. */}
        <Toasts />
      </AuthProvider>
    </QueryClientProvider>
  );
}
