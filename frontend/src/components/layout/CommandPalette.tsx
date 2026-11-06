import { useEffect, useId, useMemo, useRef, useState, type ReactNode } from "react";
import { useNavigate } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { Activity, Bell, Quote, LibraryBig, ListVideo, Rss, CornerDownLeft, FileQuestion, Film, Gauge, Home as HomeIcon, Search, Settings, Telescope, UserRound } from "lucide-react";
import { api, apiErrorMessage } from "@/api/client";
import { LIBRARY_KIND_ICONS } from "@/lib/libraries";
import { keys } from "@/lib/queryKeys";
import { hookQuery, librariesQuery } from "@/lib/queries";
import { cn } from "@/lib/cn";
import { isTypingTarget } from "@/lib/keys";
import { formatCaptured, formatClock } from "@/lib/format";
import { posterAt, wantLabel } from "@/lib/hook";
import { useAuth } from "@/hooks/useAuth";
import { useProfile } from "@/hooks/useProfile";
import { useDebouncedValue } from "@/hooks/useDebouncedValue";
import { useFormMutation } from "@/hooks/useFormMutation";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { HookShowForm } from "@/components/hook/HookShowForm";
import { Badge } from "@/components/ui/Badge";
import { FormError } from "@/components/ui/Form";
import { IconButton } from "@/components/ui/IconButton";
import type { HookHit, HookRequestKind, HookWant, ImageInfo, LibraryKind, SearchResults } from "@/types";

interface Item {
  id: string;
  group: string;
  label: string;
  detail?: string | null;
  /** Where choosing it goes; or `run`, what choosing it does. */
  to?: string;
  run?: () => void;
  icon?: ReactNode;
  image?: ImageInfo | null;
  round?: boolean;
  /** Found through Hook: drawn as a poster with its overview beneath. */
  hit?: HookHit;
  /** Beside the row, always (a badge, a key). */
  trailing?: ReactNode;
  /** Beside the active row, what Enter does. */
  hint?: string;
}

/** Stream's own library, or Hook — what the household doesn't have yet (PROPOSAL §7.9). */
type Mode = "stream" | "hook";

const ICON = "h-4 w-4 text-muted";

const hitKey = (hit: HookHit) => `${hit.kind}-${hit.provider}-${hit.external_id}`;

/** A poster Hook found on TMDB, which Stream hasn't cached: no placeholder to paint first. */
function posterImage(url: string | null): ImageInfo | null {
  return url ? { src: url, srcset: "", width: null, height: null, placeholder: null, color: null } : null;
}

/** "Heat" matches "he", "at" and "heat"; commands are few enough to filter here. */
function LibraryIcon({ kind }: { kind: LibraryKind }) {
  const Icon = LIBRARY_KIND_ICONS[kind];
  return <Icon className={ICON} aria-hidden />;
}

/** What a search found, as rows, in the order they're listed. */
function searchItems(found: SearchResults): Item[] {
  return [
    ...found.movies.map((movie) => ({
      id: `movie-${movie.id}`, group: "Movies", label: movie.title, detail: movie.year?.toString(), to: `/movie/${movie.id}`,
      image: movie.images.poster ?? null,
    })),
    ...found.shows.map((show) => ({
      id: `show-${show.id}`, group: "Shows", label: show.title, detail: show.year?.toString(), to: `/show/${show.id}`,
      image: show.images.poster ?? null,
    })),
    ...found.episodes.map((episode) => ({
      id: `episode-${episode.id}`, group: "Episodes", label: episode.title ?? episode.code,
      detail: [episode.show?.title, episode.code].filter(Boolean).join(" · "), to: `/watch/episode/${episode.id}`,
      image: episode.images.still ?? episode.images.thumb ?? null,
    })),
    ...found.channels.map((channel) => ({
      id: `channel-${channel.id}`, group: "Channels", label: channel.title, to: `/channel/${channel.id}`, image: channel.image, round: true,
    })),
    ...found.videos.map((video) => ({
      id: `video-${video.id}`, group: "Videos", label: video.title, detail: video.channel?.title, to: `/video/${video.id}`,
      image: video.images.thumb ?? null,
    })),
    ...found.clips.map((clip) => ({
      id: `clip-${clip.id}`, group: "Home videos", label: [clip.city, formatCaptured(clip, { dateStyle: "medium" })].filter(Boolean).join(" · "),
      detail: clip.title, to: `/clip/${clip.id}`, image: clip.images.thumb ?? null,
    })),
    ...found.said.map((hit) => ({
      id: `said-${hit.kind}-${hit.id}`, group: "Said in", label: hit.snippet.replace(/<<|>>/g, ""), detail: `${hit.title} · ${formatClock(hit.start)}`,
      to: hit.kind === "video" ? `/video/${hit.id}?t=${hit.start}` : `/watch/${hit.kind}/${hit.id}?t=${hit.start}`, icon: <Quote className={ICON} aria-hidden />,
    })),
    ...found.collections.map((collection) => ({
      id: `collection-${collection.id}`, group: "Collections", label: collection.title, to: `/collection/${collection.id}`,
      image: collection.image,
    })),
    ...found.people.map((person) => ({
      id: `person-${person.id}`, group: "People", label: person.name, to: `/person/${person.id}`, image: person.image, round: true,
    })),
  ];
}

function matches(label: string, query: string): boolean {
  const fold = (text: string) => text.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();
  return fold(label).includes(fold(query));
}

/**
 * ⌘K (PROPOSAL §7.2): jump anywhere, and search titles, episodes and
 * people across every library. Also opens on "/" when not typing.
 *
 * With Hook connected (PROPOSAL §7.9), the telescope — or ⇧↵ — looks
 * further: the same words searched as films and shows Hook can get. What
 * Stream already has says so and opens here; a film is requested with
 * Enter; a show opens in place to choose its seasons and follow it. Esc
 * comes back to Stream's own results.
 */
export function CommandPalette({ open, onOpenChange }: { open: boolean; onOpenChange: (open: boolean) => void }) {
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        onOpenChange(!open);
      } else if (event.key === "/" && !isTypingTarget(event.target) && !open) {
        event.preventDefault();
        onOpenChange(true);
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [open, onOpenChange]);

  // Mounted only while open, so each opening starts afresh.
  return open ? <CommandPaletteDialog onOpenChange={onOpenChange} /> : null;
}

function CommandPaletteDialog({ onOpenChange }: { onOpenChange: (open: boolean) => void }) {
  const navigate = useNavigate();
  const { user } = useAuth();
  const kid = useProfile().profile?.kind === "kid";
  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const [pendingEnter, setPendingEnter] = useState(false);
  const [mode, setMode] = useState<Mode>("stream");
  const [expanded, setExpanded] = useState<string | null>(null);
  const [asked, setAsked] = useState<Record<string, string>>({});
  const input = useRef<HTMLInputElement>(null);
  const listId = useId();
  const q = useDebouncedValue(query.trim(), 150);
  // TMDB through Hook is a slower question than Stream's own index.
  const hq = useDebouncedValue(query.trim(), 300);

  useEffect(() => {
    input.current?.focus();
    const { overflow } = document.body.style;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = overflow;
    };
  }, []);

  const { data: libraries } = useQuery(librariesQuery());
  const search = useQuery({
    queryKey: keys.search.results(q),
    queryFn: ({ signal }) => api.get<SearchResults>(`/search?q=${encodeURIComponent(q)}`, { signal }),
    enabled: mode === "stream" && q.length >= 2,
    placeholderData: (previous) => previous,
  });
  const hook = useQuery(hookQuery());
  const canAskHook = hook.data?.available === true && !kid;
  const hookSearch = (kind: HookRequestKind) => ({
    queryKey: keys.hook.search(kind, hq),
    queryFn: ({ signal }: { signal: AbortSignal }) => api.get<HookHit[]>(`/hook/search?kind=${kind}&q=${encodeURIComponent(hq)}`, { signal }),
    enabled: mode === "hook" && hq.length >= 2,
    placeholderData: (previous: HookHit[] | undefined) => previous,
    retry: false,
  });
  const hookMovies = useQuery(hookSearch("movie"));
  const hookShows = useQuery(hookSearch("show"));
  const requestMovie = useFormMutation({
    mutationFn: (hit: HookHit) => api.post<HookWant>("/hook/movies", { provider: hit.provider, external_id: hit.external_id }),
    onSuccess: (want, hit) => setAsked((all) => ({ ...all, [hitKey(hit)]: want.status })),
    fallback: "Hook couldn't take the request",
  });
  const { mutate: request, isPending: requesting } = requestMovie;

  const items = useMemo<Item[]>(() => {
    const text = query.trim();
    if (mode === "hook") {
      if (text.length < 2) return [];
      const row = (hit: HookHit, group: string): Item => {
        const key = hitKey(hit);
        const base = { id: `hook-${key}`, group, label: hit.title, hit, detail: [hit.year, hit.network].filter(Boolean).join(" · ") || null };
        const inStream = <Badge tone="success">In Stream</Badge>;
        if (hit.kind === "show") {
          return {
            ...base,
            run: () => setExpanded((current) => (current === key ? null : key)),
            trailing: hit.in_stream_id ? inStream : null,
            hint: "Choose seasons",
          };
        }
        if (hit.in_stream_id) return { ...base, to: `/movie/${hit.in_stream_id}`, trailing: inStream, hint: "Open" };
        const status = asked[key] ?? (hit.requested ? "wanted" : null);
        if (status) return { ...base, trailing: <Badge>{wantLabel(status)}</Badge> };
        return { ...base, run: () => request(hit), hint: requesting ? "Asking Hook…" : "Request" };
      };
      return [...(hookMovies.data ?? []).map((hit) => row(hit, "Movies")), ...(hookShows.data ?? []).map((hit) => row(hit, "Shows"))];
    }

    const commands: Item[] = [
      { id: "go-home", group: "Go to", label: "Home", to: "/", icon: <HomeIcon className={ICON} aria-hidden /> },
      ...(libraries ?? []).map((library) => ({
        id: `go-library-${library.id}`,
        group: "Go to",
        label: library.name,
        to: `/library/${library.id}`,
        icon: <LibraryIcon kind={library.kind} />,
      })),
      { id: "go-collections", group: "Go to", label: "Collections", to: "/collections", icon: <LibraryBig className={ICON} aria-hidden /> },
      { id: "go-subscriptions", group: "Go to", label: "Subscriptions", to: "/subscriptions", icon: <Rss className={ICON} aria-hidden /> },
      { id: "go-playlists", group: "Go to", label: "Playlists", to: "/playlists", icon: <ListVideo className={ICON} aria-hidden /> },
      { id: "go-needs-match", group: "Go to", label: "Needs match", to: "/needs-match", icon: <FileQuestion className={ICON} aria-hidden /> },
      ...(user?.role === "admin"
        ? [{ id: "go-playback", group: "Go to", label: "Playback decisions", to: "/playback", icon: <Gauge className={ICON} aria-hidden /> }]
        : []),
      { id: "go-activity", group: "Go to", label: "Activity", to: "/activity", icon: <Activity className={ICON} aria-hidden /> },
      { id: "go-notifications", group: "Go to", label: "Notifications", to: "/notifications", icon: <Bell className={ICON} aria-hidden /> },
      { id: "go-settings", group: "Go to", label: "Settings", to: "/settings", icon: <Settings className={ICON} aria-hidden /> },
    ].filter((command) => !kid || !["go-needs-match", "go-playback", "go-activity", "go-settings"].includes(command.id));
    const shown = text ? commands.filter((command) => matches(command.label, text)) : commands;
    // Last, whatever Stream finds: the same words, asked of Hook.
    const further: Item[] =
      canAskHook && text.length >= 2
        ? [
            {
              id: "ask-hook",
              group: "Not in Stream?",
              label: `Look for “${text}” in Hook`,
              run: () => setMode("hook"),
              icon: <Telescope className={ICON} aria-hidden />,
              trailing: <kbd className="hidden rounded border border-border px-1.5 text-xs text-muted sm:inline">⇧↵</kbd>,
            },
          ]
        : [];
    const found = text.length >= 2 ? search.data : undefined;
    if (!found) return [...shown, ...further];
    // A page whose name you typed beats a title that merely resembles it.
    return [
      ...shown,
      ...searchItems(found),
      ...further,
    ];
  }, [libraries, user?.role, query, search.data, kid, mode, hookMovies.data, hookShows.data, asked, canAskHook, request, requesting]);

  useEffect(() => setActive(0), [items.length, q, mode]);
  useEffect(() => setExpanded(null), [mode]);

  // Enter pressed before the results for what's typed arrived: the last
  // query's results are still on screen, so wait for these.
  const typed = query.trim();
  const settled =
    typed.length < 2 ||
    (mode === "hook" ? hq === typed && !hookMovies.isFetching && !hookShows.isFetching : q === typed && !search.isFetching);

  const choose = (item: Item | undefined) => {
    if (!item) return;
    if (item.to) {
      onOpenChange(false);
      navigate(item.to);
    } else {
      item.run?.();
    }
  };

  useEffect(() => {
    if (!pendingEnter || !settled) return;
    setPendingEnter(false);
    const first = items[0];
    if (first?.to) {
      onOpenChange(false);
      navigate(first.to);
    } else {
      first?.run?.();
    }
  }, [pendingEnter, settled, items, navigate, onOpenChange]);

  const lookFurther = () => {
    setMode("hook");
    input.current?.focus();
  };

  const onKeyDown = (event: React.KeyboardEvent) => {
    if (event.key === "ArrowDown") setActive((index) => Math.min(index + 1, items.length - 1));
    else if (event.key === "ArrowUp") setActive((index) => Math.max(index - 1, 0));
    else if (event.key === "Enter" && event.shiftKey && mode === "stream" && canAskHook) lookFurther();
    else if (event.key === "Enter") {
      if (settled) choose(items[active]);
      else setPendingEnter(true);
    } else if (event.key === "Escape") {
      if (expanded) setExpanded(null);
      else if (mode === "hook") setMode("stream");
      else onOpenChange(false);
    } else return;
    event.preventDefault();
  };

  const groups = items.reduce<{ name: string; items: { item: Item; index: number }[] }[]>((all, item, index) => {
    const last = all[all.length - 1];
    if (last && last.name === item.group) last.items.push({ item, index });
    else all.push({ name: item.group, items: [{ item, index }] });
    return all;
  }, []);
  const activeItem = items[active];
  const searching = typed.length >= 2 && (mode === "hook" ? !settled : search.isFetching || q !== typed);
  const hookFailures =
    mode === "hook"
      ? (
          [
            ["films", hookMovies.error],
            ["shows", hookShows.error],
          ] as const
        )
          .filter(([, error]) => error)
          .map(([what, error]) => apiErrorMessage(error, `Hook couldn't search ${what}.`))
      : [];
  const empty =
    mode === "stream"
      ? searching
        ? "Searching…"
        : `Nothing matches “${typed}”.`
      : typed.length < 2
        ? "Type the name of a film or a show, and Hook looks for it."
        : searching
          ? "Asking Hook…"
          : hookFailures.length > 0
            ? null
            : `Hook found nothing called “${typed}”.`;
  const LeadIcon = mode === "hook" ? Telescope : Search;

  return (
    <div className="fixed inset-0 z-[60] flex items-start justify-center bg-foreground/40 px-4 pt-[12vh]" onMouseDown={() => onOpenChange(false)}>
      <div
        role="dialog"
        aria-modal="true"
        aria-label="Search and go"
        className="w-full max-w-xl overflow-hidden rounded-[var(--radius-card)] bg-surface shadow-2xl ring-1 ring-border"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <div className="flex items-center gap-3 border-b border-border px-4">
          <LeadIcon className={cn("h-4 w-4 shrink-0", mode === "hook" ? "text-primary" : "text-muted")} aria-hidden />
          <input
            ref={input}
            role="combobox"
            aria-expanded="true"
            aria-controls={listId}
            aria-activedescendant={activeItem ? `${listId}-${activeItem.id}` : undefined}
            aria-label={mode === "hook" ? "Find a film or show for Hook to get" : "Search titles, people, or go to a page"}
            placeholder={mode === "hook" ? "Find a film or show to request…" : "Search titles, people, or go to…"}
            value={query}
            onChange={(event) => {
              setQuery(event.target.value);
              setExpanded(null);
            }}
            onKeyDown={onKeyDown}
            className="h-12 min-w-0 flex-1 bg-transparent text-sm text-foreground outline-none placeholder:text-muted"
          />
          {canAskHook ? (
            <IconButton
              label={mode === "hook" ? "Back to Stream's results" : "Look for it in Hook"}
              title={mode === "hook" ? "Back to Stream (esc)" : "Look for it in Hook (⇧↵)"}
              aria-pressed={mode === "hook"}
              onClick={() => (mode === "hook" ? setMode("stream") : lookFurther())}
              className={cn("-mr-1 p-1.5", mode === "hook" && "bg-primary/10 text-primary hover:bg-primary/15 hover:text-primary")}
            >
              <Telescope className="h-4 w-4" aria-hidden />
            </IconButton>
          ) : null}
          <kbd className="hidden rounded border border-border px-1.5 text-xs text-muted sm:inline">esc</kbd>
        </div>
        {mode === "hook" ? (
          <p className="border-b border-border bg-surface-raised px-4 py-1.5 text-xs text-muted">
            Looking in Hook for what Stream doesn't have yet. Enter requests a film; a show opens to choose its seasons.
          </p>
        ) : null}
        <div id={listId} role="listbox" aria-label="Results" className="max-h-[60vh] overflow-y-auto p-2">
          {groups.map((group) => (
            <div key={group.name} role="group" aria-label={group.name} className="pb-1">
              <p className="px-2 pb-1 pt-2 text-xs font-medium text-muted">{group.name}</p>
              {group.items.map(({ item, index }) => (
                <div key={item.id}>
                  <div
                    id={`${listId}-${item.id}`}
                    role="option"
                    aria-selected={index === active}
                    aria-expanded={item.hit?.kind === "show" ? expanded === hitKey(item.hit) : undefined}
                    onMouseMove={() => setActive(index)}
                    onClick={() => {
                      setActive(index);
                      choose(item);
                    }}
                    className={cn(
                      "flex cursor-pointer items-center gap-3 rounded-[var(--radius-control)] px-2 py-1.5 text-sm",
                      index === active ? "bg-primary/10 text-foreground" : "text-foreground/90",
                    )}
                  >
                    {item.hit ? (
                      <ArtworkImage
                        image={posterImage(posterAt(item.hit.poster_url))}
                        sizes="2rem"
                        className="h-12 w-8 shrink-0 rounded ring-1 ring-border"
                        fallback={<Film className="h-4 w-4 text-muted" aria-hidden />}
                      />
                    ) : item.icon ? (
                      <span className="flex h-8 w-8 shrink-0 items-center justify-center">{item.icon}</span>
                    ) : (
                      <ArtworkImage
                        image={item.image ?? null}
                        sizes="2rem"
                        className={cn("h-8 w-8 shrink-0 ring-1 ring-border", item.round ? "rounded-full" : "rounded")}
                        fallback={item.round ? <UserRound className="h-4 w-4 text-muted" aria-hidden /> : <Film className="h-4 w-4 text-muted" aria-hidden />}
                      />
                    )}
                    {item.hit ? (
                      <span className="min-w-0 flex-1">
                        <span className="flex min-w-0 items-baseline gap-2">
                          <span className="max-w-full shrink-0 truncate">{item.label}</span>
                          {/* On a phone the year and network give way before the title does. */}
                          {item.detail ? <span className="min-w-0 shrink-[4] truncate text-xs text-muted">{item.detail}</span> : null}
                        </span>
                        {item.hit.overview ? <span className="block truncate text-xs text-muted">{item.hit.overview}</span> : null}
                      </span>
                    ) : (
                      <>
                        <span className="min-w-0 flex-1 truncate">{item.label}</span>
                        {item.detail ? <span className="shrink-0 truncate text-xs text-muted">{item.detail}</span> : null}
                      </>
                    )}
                    {item.trailing ? <span className="shrink-0">{item.trailing}</span> : null}
                    {index === active && item.hint ? <span className="hidden shrink-0 text-xs text-muted sm:inline">{item.hint}</span> : null}
                    {index === active && (item.to || item.run) ? <CornerDownLeft className="h-3.5 w-3.5 shrink-0 text-muted" aria-hidden /> : null}
                  </div>
                  {item.hit && expanded === hitKey(item.hit) ? (
                    <HookShowForm
                      hit={item.hit}
                      onClose={() => {
                        setExpanded(null);
                        input.current?.focus();
                      }}
                      onOpen={() => onOpenChange(false)}
                    />
                  ) : null}
                </div>
              ))}
            </div>
          ))}
          {mode === "hook" ? <FormError message={requestMovie.errorMessage} className="px-2 py-1" /> : null}
          {hookFailures.map((failure) => (
            <p key={failure} role="alert" className="px-2 py-1 text-sm text-negative">
              {failure}
            </p>
          ))}
          {items.length === 0 && empty ? <p className="px-2 py-6 text-center text-sm text-muted">{empty}</p> : null}
        </div>
      </div>
    </div>
  );
}
