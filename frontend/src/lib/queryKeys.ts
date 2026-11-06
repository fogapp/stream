/**
 * The one place query keys are defined. Each resource exposes `all` as the
 * invalidation prefix, with factories nested under it, so a single
 * invalidateQueries({ queryKey: keys.x.all }) refreshes lists AND details
 * (react-query matches by prefix). Inline key literals are lint-banned.
 */
import type { ApiQuery } from "@/lib/tableParams";
import type { ActivitySeverity, HookRequestKind } from "@/types";

export const keys = {
  session: {
    all: ["session"] as const,
    setup: () => [...keys.session.all, "setup"] as const,
  },
  notifications: {
    all: ["notifications"] as const,
    unreadCount: () => [...keys.notifications.all, "unreadCount"] as const,
    list: (page: number) => [...keys.notifications.all, "list", { page }] as const,
  },
  activity: {
    all: ["activity"] as const,
    list: (filters: { severity?: ActivitySeverity; page?: number; per?: number }) =>
      [...keys.activity.all, "list", filters] as const,
  },
  about: {
    all: ["about"] as const,
    detail: () => [...keys.about.all, "detail"] as const,
  },
  users: {
    all: ["users"] as const,
    list: () => [...keys.users.all, "list"] as const,
  },
  passkeys: {
    all: ["passkeys"] as const,
    list: () => [...keys.passkeys.all, "list"] as const,
  },
  jobs: {
    all: ["jobs"] as const,
    list: () => [...keys.jobs.all, "list"] as const,
  },
  settings: {
    all: ["settings"] as const,
    general: () => [...keys.settings.all, "general"] as const,
  },
  liveStreams: {
    all: ["live-streams"] as const,
    list: (libraryId?: string) => [...keys.liveStreams.all, "list", libraryId ?? "all"] as const,
  },
  libraries: {
    all: ["libraries"] as const,
    list: () => [...keys.libraries.all, "list"] as const,
    fogSuggestions: () => [...keys.libraries.all, "fog-suggestions"] as const,
  },
  mediaFiles: {
    all: ["mediaFiles"] as const,
    detail: (id: string) => [...keys.mediaFiles.all, "detail", id] as const,
  },
  tmdb: {
    all: ["tmdb"] as const,
    settings: () => [...keys.tmdb.all, "settings"] as const,
  },
  profileTags: {
    all: ["profileTags"] as const,
    item: (type: string, id: string) => [...keys.profileTags.all, type, id] as const,
  },
  profiles: {
    all: ["profiles"] as const,
    current: () => [...keys.profiles.all, "current"] as const,
    list: () => [...keys.profiles.all, "list"] as const,
    content: (id: string) => [...keys.profiles.all, "content", id] as const,
  },
  plex: {
    all: ["plex"] as const,
    connection: () => [...keys.plex.all, "connection"] as const,
    imports: () => [...keys.plex.all, "imports"] as const,
  },
  arr: {
    all: ["arr"] as const,
    settings: () => [...keys.arr.all, "settings"] as const,
  },
  matches: {
    all: ["matches"] as const,
    list: () => [...keys.matches.all, "list"] as const,
    folders: () => [...keys.matches.all, "folders"] as const,
  },
  home: {
    all: ["home"] as const,
    hubs: () => [...keys.home.all, "hubs"] as const,
  },
  sidebar: {
    all: ["sidebar"] as const,
    layout: () => [...keys.sidebar.all, "layout"] as const,
  },
  catalog: {
    all: ["catalog"] as const,
    version: () => [...keys.catalog.all, "version"] as const,
  },
  search: {
    all: ["search"] as const,
    results: (q: string) => [...keys.search.all, "results", q] as const,
  },
  hook: {
    all: ["hook"] as const,
    availability: () => [...keys.hook.all, "availability"] as const,
    search: (kind: HookRequestKind, q: string) => [...keys.hook.all, "search", kind, q] as const,
    show: (provider: string, externalId: string) => [...keys.hook.all, "show", provider, externalId] as const,
  },
  subscriptions: {
    all: ["subscriptions"] as const,
    feed: () => [...keys.subscriptions.all, "feed"] as const,
  },
  watchLater: {
    all: ["watchLater"] as const,
    ids: () => [...keys.watchLater.all, "ids"] as const,
  },
  immich: {
    all: ["immich"] as const,
    settings: () => [...keys.immich.all, "settings"] as const,
  },
  trakt: {
    all: ["trakt"] as const,
    settings: () => [...keys.trakt.all, "settings"] as const,
    account: () => [...keys.trakt.all, "account"] as const,
  },
  mlb: {
    all: ["mlb"] as const,
    settings: () => [...keys.mlb.all, "settings"] as const,
  },
  nba: {
    all: ["nba"] as const,
    settings: () => [...keys.nba.all, "settings"] as const,
  },
  basketball: {
    all: ["basketball"] as const,
    availability: () => [...keys.basketball.all, "availability"] as const,
    day: (date: string | null) => [...keys.basketball.all, "day", date ?? "today"] as const,
  },
  baseball: {
    all: ["baseball"] as const,
    availability: () => [...keys.baseball.all, "availability"] as const,
    day: (date: string | null) => [...keys.baseball.all, "day", date ?? "today"] as const,
  },
  openSubtitles: {
    all: ["openSubtitles"] as const,
    settings: () => [...keys.openSubtitles.all, "settings"] as const,
  },
  whisper: {
    all: ["whisper"] as const,
    settings: () => [...keys.whisper.all, "settings"] as const,
  },
  transcripts: {
    all: ["transcripts"] as const,
    detail: (kind: string, id: string) => [...keys.transcripts.all, kind, id] as const,
  },
  stats: {
    all: ["stats"] as const,
    nowPlaying: () => [...keys.stats.all, "now"] as const,
    history: (page: number) => [...keys.stats.all, "history", page] as const,
    summary: (days: number) => [...keys.stats.all, "summary", days] as const,
  },
  notificationPreferences: {
    all: ["notificationPreferences"] as const,
    current: () => [...keys.notificationPreferences.all, "current"] as const,
  },
  sponsorblock: {
    all: ["sponsorblock"] as const,
    preferences: () => [...keys.sponsorblock.all, "preferences"] as const,
  },
  youtube: {
    all: ["youtube"] as const,
    status: () => [...keys.youtube.all, "status"] as const,
    tracking: (channelId: string) => [...keys.youtube.all, "tracking", channelId] as const,
  },
  channels: {
    all: ["channels"] as const,
    list: (filters: { library_id?: string; q?: string }) => [...keys.channels.all, "list", filters] as const,
    detail: (id: string, filters: { sort?: string; unwatched?: boolean }) => [...keys.channels.all, "detail", id, filters] as const,
  },
  clips: {
    all: ["clips"] as const,
    filters: (libraryId: string) => [...keys.clips.all, "filters", libraryId] as const,
    places: (libraryId: string) => [...keys.clips.all, "places", libraryId] as const,
    list: (filters: { library_id?: string; album_id?: string; person_id?: string; favorites?: boolean; from?: number | null }) =>
      [...keys.clips.all, "list", filters] as const,
    detail: (id: string) => [...keys.clips.all, "detail", id] as const,
  },
  videos: {
    all: ["videos"] as const,
    feed: (filters: { library_id: string; channel_id?: string; unwatched: boolean }) => [...keys.videos.all, "feed", filters] as const,
    detail: (id: string) => [...keys.videos.all, "detail", id] as const,
  },
  playlists: {
    all: ["playlists"] as const,
    list: () => [...keys.playlists.all, "list"] as const,
    detail: (id: string) => [...keys.playlists.all, "detail", id] as const,
  },
  collections: {
    all: ["collections"] as const,
    list: (libraryId?: string) => [...keys.collections.all, "list", libraryId ?? "all"] as const,
    detail: (id: string) => [...keys.collections.all, "detail", id] as const,
  },
  people: {
    all: ["people"] as const,
    detail: (id: string) => [...keys.people.all, "detail", id] as const,
  },
  movies: {
    all: ["movies"] as const,
    similar: (id: string) => [...keys.movies.all, "similar", id] as const,
    list: (filters: { library_id?: string; sort?: string; unwatched?: boolean; q?: string }) =>
      [...keys.movies.all, "list", filters] as const,
    letters: (filters: { library_id?: string; unwatched?: boolean; q?: string }) => [...keys.movies.all, "letters", filters] as const,
    detail: (id: string) => [...keys.movies.all, "detail", id] as const,
  },
  shows: {
    all: ["shows"] as const,
    similar: (id: string) => [...keys.shows.all, "similar", id] as const,
    list: (filters: { library_id?: string; sort?: string; unwatched?: boolean; q?: string }) =>
      [...keys.shows.all, "list", filters] as const,
    letters: (filters: { library_id?: string; unwatched?: boolean; q?: string }) => [...keys.shows.all, "letters", filters] as const,
    detail: (id: string) => [...keys.shows.all, "detail", id] as const,
    season: (id: string, season: number) => [...keys.shows.all, "season", id, season] as const,
    info: (id: string) => [...keys.shows.all, "info", id] as const,
  },
  playback: {
    all: ["playback"] as const,
  },
  artworkChoices: {
    all: ["artworkChoices"] as const,
    list: (ownerType: string, ownerId: string, kind: string) => [...keys.artworkChoices.all, ownerType, ownerId, kind] as const,
  },
  remote: {
    all: ["remote"] as const,
    thisDevice: () => [...keys.remote.all, "thisDevice"] as const,
    devices: () => [...keys.remote.all, "devices"] as const,
  },
  transcodeNodes: {
    all: ["transcodeNodes"] as const,
    list: () => [...keys.transcodeNodes.all, "list"] as const,
  },
  optimizedVersions: {
    all: ["optimizedVersions"] as const,
    list: (query: ApiQuery) => [...keys.optimizedVersions.all, "list", query] as const,
    status: () => [...keys.optimizedVersions.all, "status"] as const,
  },
  playbackDecisions: {
    all: ["playbackDecisions"] as const,
    list: (query: ApiQuery) => [...keys.playbackDecisions.all, "list", query] as const,
    detail: (id: string) => [...keys.playbackDecisions.all, "detail", id] as const,
    facets: () => [...keys.playbackDecisions.all, "facets"] as const,
    health: () => [...keys.playbackDecisions.all, "health"] as const,
    summary: () => [...keys.playbackDecisions.all, "summary"] as const,
    report: (query: ApiQuery) => [...keys.playbackDecisions.all, "report", query] as const,
    lessons: (query: ApiQuery) => [...keys.playbackDecisions.all, "lessons", query] as const,
  },
  apiTokens: {
    all: ["apiTokens"] as const,
    list: () => [...keys.apiTokens.all, "list"] as const,
  },
  live: {
    all: ["live"] as const,
    guide: (from: string, to: string) => [...keys.live.all, "guide", { from, to }] as const,
    stations: (hidden: boolean) => [...keys.live.all, "stations", { hidden }] as const,
    station: (id: string) => [...keys.live.all, "station", id] as const,
    options: () => [...keys.live.all, "options"] as const,
    preview: (draft: object) => [...keys.live.all, "preview", draft] as const,
    preset: (kind: string, value: string) => [...keys.live.all, "preset", kind, value] as const,
  },
} as const;
