// Settings › Import from Plex (plex_serializer).

import type { JobRunStatus, Testable } from "@/types/core";

export interface PlexUserMappingInfo {
  id: string;
  plex_name: string;
  plex_admin: boolean;
  profile_id: string | null;
}

/** Settings › Import from Plex (PlexSerializer.connection_json). Never the token. */
export type PlexConnectionInfo =
  | { connected: false }
  | ({
      connected: true;
      server_url: string;
      server_name: string | null;
      sync_enabled: boolean;
      last_synced_at: string | null;
      users: PlexUserMappingInfo[];
    } & Testable);

export interface PlexImportRun {
  id: string;
  dry_run: boolean;
  status: JobRunStatus;
  counts: Record<string, number>;
  unmatched: { kind: "movie" | "episode"; title: string }[];
  users: ({ plex_name: string; profile: string | null; error?: string } & Record<string, unknown>)[];
  error: string | null;
  started_at: string | null;
  finished_at: string | null;
  created_at: string;
}
