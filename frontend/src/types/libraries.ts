// Libraries and files (app/serializers/library_serializer.rb,
// media_file_serializer.rb).

export const LIBRARY_KINDS = ["movies", "shows", "channels", "home_videos", "live"] as const;

export type LibraryKind = (typeof LIBRARY_KINDS)[number];

export const MEDIA_FILE_STATES = ["discovered", "probed", "broken", "missing"] as const;

export type MediaFileState = (typeof MEDIA_FILE_STATES)[number];

export interface LibraryScanCounts {
  seen?: number;
  added?: number;
  changed?: number;
  missing?: number;
  purged?: number;
  unread?: number;
}

/** A folder fog mounts that no library reads yet, and the library it would join (GET /libraries/fog_suggestions). */
export interface FogLibrarySuggestion {
  root: string;
  /** The Drive folder's name, e.g. "Movies". */
  name: string;
  kind: LibraryKind;
  library_id: string | null;
  library_name: string | null;
}

export interface Library {
  id: string;
  name: string;
  kind: LibraryKind;
  roots: string[];
  metadata_language: string;
  scanning: boolean;
  last_scanned_at: string | null;
  last_scan_started_at: string | null;
  last_scan_error: string | null;
  consecutive_scan_failures: number;
  last_scan_counts: LibraryScanCounts;
  file_counts: Record<MediaFileState, number>;
  created_at: string;
}
