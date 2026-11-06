import { useState, type ReactNode } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Clapperboard, Film, Image, Search, Tv } from "lucide-react";
import { api } from "@/api/client";
import { PROFILE_CONTENT_KIND_LABELS } from "@/lib/profileContent";
import { keys } from "@/lib/queryKeys";
import { useDebouncedValue } from "@/hooks/useDebouncedValue";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import type { HideableKind, ImageInfo, ProfileContent, ProfileContentItem, ProfileInfo, SearchResults } from "@/types";

const KIND_ICONS: Record<ProfileContentItem["kind"], typeof Film> = { movie: Film, show: Tv, channel: Clapperboard, album: Image };

/** What's hidden from (and tagged for) one profile, read once for both cards. */
function useProfileContent(profileId: string) {
  return useQuery({ queryKey: keys.profiles.content(profileId), queryFn: ({ signal }) => api.get<ProfileContent>(`/profiles/${profileId}/content`, { signal }) });
}

/**
 * Hidden from this profile: movies, shows and YouTube channels that appear
 * nowhere on it (Viewing::Access), whatever its rating or tags say. Hide more
 * by searching here or with "Hide from me" on a title's page.
 */
export function HiddenTitles({ profile, self = false }: { profile: Pick<ProfileInfo, "id" | "name">; self?: boolean }) {
  const queryClient = useQueryClient();
  const content = useProfileContent(profile.id);
  const change = useMutation({
    mutationFn: ({ kind, id, hidden }: { kind: HideableKind; id: string; hidden: boolean }) =>
      api.put<ProfileContent>(`/profiles/${profile.id}/content/hidden`, { kind, id, hidden }),
    onSuccess: (data) => {
      queryClient.setQueryData(keys.profiles.content(profile.id), data);
      // Rows, search and pages the profile has cached change with it.
      if (self) void queryClient.invalidateQueries({ predicate: (query) => query.queryKey[0] !== "profiles" });
    },
  });
  const hiddenKeys = new Set((content.data?.hidden ?? []).map((item) => `${item.kind}:${item.id}`));

  return (
    <Card>
      <CardHeader
        title={self ? `Hidden from ${profile.name}` : "Hidden from this profile"}
        description="Movies, shows and YouTube channels that appear nowhere on this profile: not in rows, search, the Grid or their own pages."
      />
      <CardBody className="space-y-4">
        <HideSearch hidden={hiddenKeys} pending={change.isPending} onHide={(kind, id) => change.mutate({ kind, id, hidden: true })} />
        <QueryState
          query={content}
          errorMessage="Could not load what's hidden."
          isEmpty={(data) => data.hidden.length === 0}
          empty={<EmptyState title="Nothing hidden" description="Search above, or use “Hide from me” on a title's page." />}
        >
          {(data) => (
            <ContentList
              items={data.hidden}
              action={({ kind, id }) =>
                kind === "album" ? null : (
                  <Button size="sm" variant="secondary" disabled={change.isPending} onClick={() => change.mutate({ kind, id, hidden: false })}>
                    Show again
                  </Button>
                )
              }
            />
          )}
        </QueryState>
      </CardBody>
    </Card>
  );
}

/** "For this profile" tags, listed in one place (they're set from each title's page). Admins only. */
export function TaggedTitles({ profile }: { profile: Pick<ProfileInfo, "id" | "curated"> }) {
  const queryClient = useQueryClient();
  const content = useProfileContent(profile.id);
  const untag = useMutation({
    mutationFn: (item: ProfileContentItem) =>
      api.put("/profile_tags", { profile_id: profile.id, taggable_type: item.kind, taggable_id: item.id, tagged: false }),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: keys.profiles.content(profile.id) });
      void queryClient.invalidateQueries({ queryKey: keys.profileTags.all });
    },
  });

  return (
    <Card>
      <CardHeader
        title="Tagged for this profile"
        description={
          profile.curated
            ? "A curated profile sees only these. Tag more with “For profiles” on a title's page."
            : "Let past the rating limit. Tag more with “For profiles” on a title's page."
        }
      />
      <CardBody>
        <QueryState
          query={content}
          errorMessage="Could not load what's tagged."
          isEmpty={(data) => (data.tagged ?? []).length === 0}
          empty={<EmptyState title="Nothing tagged" />}
        >
          {(data) => (
            <ContentList
              items={data.tagged ?? []}
              action={(item) => (
                <Button size="sm" variant="secondary" disabled={untag.isPending} onClick={() => untag.mutate(item)}>
                  Untag
                </Button>
              )}
            />
          )}
        </QueryState>
      </CardBody>
    </Card>
  );
}

function ContentList({ items, action }: { items: ProfileContentItem[]; action: (item: ProfileContentItem) => ReactNode }) {
  return (
    <ul className="divide-y divide-border">
      {items.map((item) => (
        <ContentRow key={`${item.kind}:${item.id}`} kind={item.kind} title={item.title} detail={item.detail} image={item.image}>
          {action(item)}
        </ContentRow>
      ))}
    </ul>
  );
}

function ContentRow({
  kind,
  title,
  detail,
  image,
  children,
}: {
  kind: ProfileContentItem["kind"];
  title: string;
  detail: string | null;
  image: ImageInfo | null | undefined;
  children?: ReactNode;
}) {
  const Icon = KIND_ICONS[kind];
  return (
    <li className="flex items-center gap-3 py-2.5">
      <ArtworkImage
        image={image}
        sizes="2.5rem"
        className={kind === "channel" ? "h-10 w-10 shrink-0 rounded-full bg-surface-raised" : "h-14 w-10 shrink-0 rounded bg-surface-raised"}
        fallback={<Icon className="h-4 w-4 text-muted" aria-hidden />}
      />
      <div className="min-w-0 flex-1">
        <p className="truncate font-medium text-foreground">{title}</p>
        <p className="truncate text-sm text-muted">{[PROFILE_CONTENT_KIND_LABELS[kind], detail].filter(Boolean).join(" · ")}</p>
      </div>
      {children}
    </li>
  );
}

/** Find a movie, show or channel to hide. Searches as whoever is signed in here. */
function HideSearch({ hidden, pending, onHide }: { hidden: Set<string>; pending: boolean; onHide: (kind: HideableKind, id: string) => void }) {
  const [q, setQ] = useState("");
  const query = useDebouncedValue(q.trim(), 250);
  const results = useQuery({
    queryKey: keys.search.results(query),
    queryFn: ({ signal }) => api.get<SearchResults>(`/search?q=${encodeURIComponent(query)}`, { signal }),
    enabled: query.length >= 2,
  });
  const found: { kind: HideableKind; id: string; title: string; detail: string | null; image: ImageInfo | null | undefined }[] = [
    ...(results.data?.movies ?? []).map((m) => ({ kind: "movie" as const, id: m.id, title: m.title, detail: m.year?.toString() ?? null, image: m.images.poster })),
    ...(results.data?.shows ?? []).map((s) => ({ kind: "show" as const, id: s.id, title: s.title, detail: s.year?.toString() ?? null, image: s.images.poster })),
    ...(results.data?.channels ?? []).map((c) => ({ kind: "channel" as const, id: c.id, title: c.title, detail: null, image: c.image })),
  ].filter((item) => !hidden.has(`${item.kind}:${item.id}`));

  return (
    <div className="space-y-2">
      <Input
        label="Hide a title"
        name="hide-search"
        type="search"
        placeholder="Search movies, shows and YouTube channels"
        icon={<Search className="h-4 w-4" />}
        value={q}
        onChange={(event) => setQ(event.target.value)}
      />
      {query.length >= 2 && results.data ? (
        found.length === 0 ? (
          <p className="text-sm text-muted">No movies, shows or channels match.</p>
        ) : (
          <ul className="divide-y divide-border rounded-[var(--radius-card)] border border-border px-3">
            {found.slice(0, 8).map((item) => (
              <ContentRow key={`${item.kind}:${item.id}`} kind={item.kind} title={item.title} detail={item.detail} image={item.image}>
                <Button size="sm" disabled={pending} onClick={() => onHide(item.kind, item.id)}>
                  Hide
                </Button>
              </ContentRow>
            ))}
          </ul>
        )
      ) : null}
      {results.isError ? <p className="text-sm text-negative">Search didn't work. Try again.</p> : null}
    </div>
  );
}
