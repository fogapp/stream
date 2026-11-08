import { queryOptions } from "@tanstack/react-query";
import { api } from "@/api/client";
import { refreshEvery as baseballRefreshEvery } from "@/lib/baseball";
import { keys } from "@/lib/queryKeys";
import type {
  About,
  BaseballAvailability,
  BaseballDay,
  BasketballAvailability,
  HomeHubs,
  HookAvailability,
  Library,
  LiveStream,
  PlaylistCard,
  ProfileInfo,
  SearchResults,
  SeasonDetail,
  Station,
  VideoDetail,
} from "@/types";

/**
 * Queries several screens share, defined once so every screen asks the same
 * way and caches the same way. This is reference data: it changes when
 * someone edits it in Settings, and those edits invalidate these keys, so a
 * minute's staleness only spares refetches — it never shows an edit late.
 */
const REFERENCE_STALE_MS = 60_000;

export const aboutQuery = () =>
  queryOptions({ queryKey: keys.about.detail(), queryFn: ({ signal }) => api.get<About>("/about", { signal }), staleTime: REFERENCE_STALE_MS });

/** The household's libraries: the sidebar's, the pickers' and Settings'. */
export const librariesQuery = () =>
  queryOptions({ queryKey: keys.libraries.list(), queryFn: ({ signal }) => api.get<Library[]>("/libraries", { signal }), staleTime: REFERENCE_STALE_MS });

export const profilesQuery = () =>
  queryOptions({ queryKey: keys.profiles.list(), queryFn: ({ signal }) => api.get<ProfileInfo[]>("/profiles", { signal }), staleTime: REFERENCE_STALE_MS });

/** The watching profile's playlists. Adding to one invalidates this key. */
export const playlistsQuery = () =>
  queryOptions({ queryKey: keys.playlists.list(), queryFn: ({ signal }) => api.get<PlaylistCard[]>("/playlists", { signal }), staleTime: REFERENCE_STALE_MS });

/** Whether the household has an MLB.tv account: Baseball in the sidebar, and its games in Picture in picture. Saving or forgetting the account invalidates it. */
export const baseballQuery = () =>
  queryOptions({
    queryKey: keys.baseball.availability(),
    queryFn: ({ signal }) => api.get<BaseballAvailability>("/baseball", { signal }),
    staleTime: REFERENCE_STALE_MS,
  });

/** Whether the household turned on NBA League Pass: Basketball in the sidebar. Turning it on or off invalidates it. */
export const basketballQuery = () =>
  queryOptions({
    queryKey: keys.basketball.availability(),
    queryFn: ({ signal }) => api.get<BasketballAvailability>("/basketball", { signal }),
    staleTime: REFERENCE_STALE_MS,
  });

/** Whether Hook is connected: fog sets that, and redeploys. */
export const hookQuery = () =>
  queryOptions({ queryKey: keys.hook.availability(), queryFn: ({ signal }) => api.get<HookAvailability>("/hook", { signal }), staleTime: 5 * 60_000 });

/** A live library's cameras and web streams. */
export const liveStreamsQuery = (libraryId: string) =>
  queryOptions({
    queryKey: keys.liveStreams.list(libraryId),
    queryFn: ({ signal }) => api.get<LiveStream[]>(`/live_streams?library_id=${libraryId}`, { signal }),
    // The pictures are retaken every few minutes, and whether each answers;
    // a new stream's first picture is a few seconds away.
    refetchInterval: (query) => (query.state.data?.some((stream) => !stream.still_url) ? 5_000 : 60_000),
  });

/*
 * Queries more than one screen reads, so they share a cache entry: each
 * site spreads the factory and adds its own `enabled` or `placeholderData`.
 * Not reference data, so no staleTime beyond the client's default.
 */

/** The home screen's rows: Home, the TV's home, and Picture in picture's picker. */
export const homeHubsQuery = () => queryOptions({ queryKey: keys.home.hubs(), queryFn: ({ signal }) => api.get<HomeHubs>("/home", { signal }) });

/** One season's episodes: the show page, the TV's title page, Shuffle, the player's panel. */
export const seasonQuery = (showId: string, number: number) =>
  queryOptions({
    queryKey: keys.shows.season(showId, number),
    queryFn: ({ signal }) => api.get<SeasonDetail>(`/shows/${showId}/seasons/${number}`, { signal }),
  });

/** A YouTube video's page: its detail, the player's end screen and panel. */
export const videoQuery = (id: string) =>
  queryOptions({ queryKey: keys.videos.detail(id), queryFn: ({ signal }) => api.get<VideoDetail>(`/videos/${id}`, { signal }) });

/** The catalog's search. Sites gate it on a minimum length with `enabled`. */
export const searchQuery = (q: string) =>
  queryOptions({ queryKey: keys.search.results(q), queryFn: ({ signal }) => api.get<SearchResults>(`/search?q=${encodeURIComponent(q)}`, { signal }) });

/** Grid's channels; `hidden` includes the ones this profile hid. */
export const stationsQuery = (hidden: boolean) =>
  queryOptions({
    queryKey: keys.live.stations(hidden),
    queryFn: ({ signal }) => api.get<Station[]>(hidden ? "/stations?hidden=1" : "/stations", { signal }),
  });

/** A day of baseball (today when null), refreshed while games are on. */
export const baseballDayQuery = (date: string | null) =>
  queryOptions({
    queryKey: keys.baseball.day(date),
    queryFn: ({ signal }) => api.get<BaseballDay>(`/baseball/games${date ? `?date=${encodeURIComponent(date)}` : ""}`, { signal }),
    refetchInterval: (query) => baseballRefreshEvery(query.state.data),
  });
