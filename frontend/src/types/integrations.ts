// Settings › Integrations: each connection as its serializer shows it
// (integration_setting_serializer, tmdb_setting_serializer, trakt_serializer,
// the Arr webhooks). Secrets are write-only and never appear here.

import type { Testable } from "@/types/core";

/** Settings › Integrations › TMDB (TmdbSettingSerializer). Never the key. */
export interface TmdbSettings extends Testable {
  configured: boolean;
}

export type OpenSubtitlesSettings =
  | { configured: false }
  | ({
      configured: true;
      username: string | null;
      languages: string[];
      enabled: boolean;
      remaining_downloads: number | null;
      resets_at: string | null;
    } & Testable);

export type TraktSettings =
  | { configured: false }
  | ({
      configured: true;
      client_id: string;
    } & Testable);

export const TRAKT_LINK_STATES = ["pending", "linked", "needs_relink"] as const;

export type TraktLinkState = (typeof TRAKT_LINK_STATES)[number];

export interface TraktLink {
  state: TraktLinkState;
  username: string | null;
  linked_at: string | null;
  last_synced_at: string | null;
  last_error: string | null;
  last_error_at: string | null;
  user_code: string | null;
  verification_url: string | null;
  code_expires_at: string | null;
  poll_interval: number | null;
}

export interface TraktAccountInfo {
  available: boolean;
  account: TraktLink | null;
}

export interface PathMappingInfo {
  id: string;
  remote_prefix: string;
  local_prefix: string;
}

/** Settings › Integrations › Sonarr & Radarr (ArrWebhooksController#json_for). */
export interface ArrWebhookSettings {
  url: string;
  last_received_at: string | null;
  last_source: string | null;
  last_event: string | null;
  last_outcome: string | null;
  path_mappings: PathMappingInfo[];
}

/** WhisperSetting::ApiKind: which API the Whisper server speaks. */
export const WHISPER_API_KINDS = ["asr_webservice", "openai"] as const;

export type WhisperApiKind = (typeof WHISPER_API_KINDS)[number];

export type ImmichSettings =
  | { configured: false }
  | ({
      configured: true;
      url: string;
      immich_path_prefix: string | null;
      local_path_prefix: string | null;
      enabled: boolean;
      last_synced_at: string | null;
      last_sync_error: string | null;
      last_sync_counts: Record<string, number>;
    } & Testable);

export type WhisperSettings =
  | { configured: false }
  | ({
      configured: true;
      url: string;
      api_kind: WhisperApiKind;
      model: string | null;
      enabled: boolean;
      api_key_set: boolean;
    } & Testable);

/** The household's MLB.tv account (app/serializers/integration_setting_serializer.rb). The password is write-only. */
export type MlbSettings =
  | { configured: false }
  | ({
      configured: true;
      username: string;
    } & Testable);

/** NBA League Pass (app/serializers/integration_setting_serializer.rb): on or off, with no account kept. */
export type NbaSettings = { configured: false } | ({ configured: true } & Testable);
