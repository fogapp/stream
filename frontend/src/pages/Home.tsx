import { useEffect, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { ArrowDown, ArrowUp, Info, SlidersHorizontal } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { homeHubsQuery } from "@/lib/queries";
import { useAuth } from "@/hooks/useAuth";
import { PosterCard, WideCard } from "@/components/viewing/cards";
import { Hero } from "@/components/viewing/Hero";
import { PlayButtons } from "@/components/viewing/PlayButton";
import { ProgressBar } from "@/components/ui/ProgressBar";
import { ROW_POSTER, ROW_WIDE, Row } from "@/components/viewing/Row";
import { VideoTile } from "@/components/viewing/VideoTile";
import { ClipTile } from "@/components/viewing/ClipTile";
import { Button } from "@/components/ui/Button";
import { Checkbox } from "@/components/ui/Checkbox";
import { IconButton } from "@/components/ui/IconButton";
import { Menu } from "@/components/ui/Menu";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import type { HomeHero, HomeHub, HomeHubs } from "@/types";

/**
 * The home screen (PROPOSAL §7.1): a hero — something you were watching,
 * what's next, or new, different each visit — then the hubs in the order
 * this profile chose.
 */
export function Home() {
  const hubs = useQuery(homeHubsQuery());
  const { user } = useAuth();

  return (
    <div className="pb-8">
      <QueryState query={hubs} errorMessage="Could not load the home screen.">
        {(home) => {
          if (home.hubs.length === 0 && !home.hero) {
            return (
              <div className="py-6 lg:py-8">
                <EmptyState
                  title="Nothing to watch yet"
                  description={
                    user?.role === "admin"
                      ? "Add a library for your movies and one for your TV shows, and they'll appear here as they're read."
                      : "An admin needs to add a library first."
                  }
                  action={
                    user?.role === "admin" ? (
                      <Link to="/settings?tab=libraries">
                        <Button>Add a library</Button>
                      </Link>
                    ) : null
                  }
                />
              </div>
            );
          }
          return (
            <>
              <HomeHeroPick home={home} />
              <div className="space-y-8 pt-6">
                {home.hubs.map((hub) => (
                  <HubRow key={hub.key} hub={hub} />
                ))}
                <div className="px-4 sm:px-6 lg:px-8">
                  <Customize layout={home.layout} />
                </div>
              </div>
            </>
          );
        }}
      </QueryState>
    </div>
  );
}

/**
 * A different title at the top each time Home is visited, picked from the
 * server's candidates — then kept while the page is open, so a refetch
 * refreshes its progress rather than swapping it (and its trailer) out.
 */
function HomeHeroPick({ home }: { home: HomeHubs }) {
  const [pickedId] = useState(() => home.heroes[Math.floor(Math.random() * home.heroes.length)]?.id);
  const hero = home.heroes.find((candidate) => candidate.id === pickedId) ?? home.hero;
  return hero ? <HomeHeroSection hero={hero} /> : null;
}

function HomeHeroSection({ hero }: { hero: HomeHero }) {
  const detail = hero.kind === "movie" ? `/movie/${hero.id}` : `/show/${hero.id}`;
  return (
    <Hero images={hero.images} title={hero.title} trailerUrl={hero.trailer?.url}>
      <div className="space-y-2">
        <p className="text-xs font-semibold uppercase tracking-wider text-primary">{hero.label}</p>
        {hero.subtitle ? <p className="text-sm text-muted">{hero.subtitle}</p> : null}
        {hero.progress ? <ProgressBar variant="overlay" value={hero.progress} className="max-w-sm rounded-full" /> : null}
        {hero.overview ? <p className="line-clamp-3 max-w-2xl text-sm leading-relaxed text-foreground/90 sm:text-base">{hero.overview}</p> : null}
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <PlayButtons kind={hero.play.kind} id={hero.play.id} resumeAt={hero.resume_at} />
        <Link to={detail}>
          <Button size="lg" variant="ghost">
            <Info className="h-4 w-4" aria-hidden />
            More info
          </Button>
        </Link>
      </div>
    </Hero>
  );
}

function HubRow({ hub }: { hub: HomeHub }) {
  const queryClient = useQueryClient();
  const dismiss = useMutation({
    mutationFn: (item: { kind: string; id: string }) => api.post("/watch_states/hide", { playable_type: item.kind, playable_id: item.id }),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: keys.home.all }),
  });

  if (hub.kind === "clips") {
    return (
      <Row title={hub.title}>
        {hub.items.map((item) => (
          <ClipTile key={item.id} clip={item} className={ROW_WIDE} showDate />
        ))}
      </Row>
    );
  }
  if (hub.kind === "videos") {
    return (
      <Row title={hub.title}>
        {hub.items.map((item) => (
          <VideoTile key={item.id} video={item} className={ROW_WIDE} />
        ))}
      </Row>
    );
  }
  if (hub.kind === "poster") {
    return (
      <Row title={hub.title}>
        {hub.items.map((item) => (
          <PosterCard key={`${item.kind}-${item.id}`} item={item} className={ROW_POSTER} />
        ))}
      </Row>
    );
  }
  return (
    <Row title={hub.title}>
      {hub.items.map((item) => (
        <WideCard
          key={`${item.kind}-${item.id}`}
          item={item}
          className={ROW_WIDE}
          onDismiss={hub.kind === "continue" || hub.key === "next_up" ? { from: hub.title, dismiss: () => dismiss.mutate(item) } : undefined}
        />
      ))}
    </Row>
  );
}

/** Show, hide and reorder the hubs, for this profile. */
function Customize({ layout }: { layout: HomeHubs["layout"] }) {
  const queryClient = useQueryClient();
  const save = useMutation({
    // One save at a time, in order: two quick changes must land as the second.
    scope: { id: "home-layout" },
    mutationFn: (next: HomeHubs["layout"]) =>
      api.patch<HomeHubs>("/home", { order: next.map((hub) => hub.key), hidden: next.filter((hub) => hub.hidden).map((hub) => hub.key) }),
    onSuccess: (home) => queryClient.setQueryData(keys.home.hubs(), home),
  });
  // Shown at once; the server's answer (the rows themselves) follows.
  const [draft, setDraft] = useState(layout);
  useEffect(() => setDraft(layout), [layout]);
  const change = (next: HomeHubs["layout"]) => {
    setDraft(next);
    save.mutate(next);
  };

  const move = (index: number, by: -1 | 1) => {
    const next = [...draft];
    const [hub] = next.splice(index, 1);
    if (!hub) return;
    next.splice(index + by, 0, hub);
    change(next);
  };

  return (
    <Menu label="Customize home" align="left" placement="above" icon={<SlidersHorizontal className="h-4 w-4" aria-hidden />}>
      <div className="space-y-1">
        {draft.map((hub, index) => (
          <div key={hub.key} className="flex items-center gap-1">
            <Checkbox
              className="min-w-0 flex-1"
              label={hub.title}
              checked={!hub.hidden}
              onChange={(shown) => change(draft.map((other) => (other.key === hub.key ? { ...other, hidden: !shown } : other)))}
            />
            <IconButton label={`Move ${hub.title} up`} disabled={index === 0} onClick={() => move(index, -1)}>
              <ArrowUp className="h-3.5 w-3.5" aria-hidden />
            </IconButton>
            <IconButton label={`Move ${hub.title} down`} disabled={index === draft.length - 1} onClick={() => move(index, 1)}>
              <ArrowDown className="h-3.5 w-3.5" aria-hidden />
            </IconButton>
          </div>
        ))}
      </div>
    </Menu>
  );
}
