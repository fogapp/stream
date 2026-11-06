import type { EncoderKind } from "@/types/transcoders";

/** Another record, named: what a row carries about something it points at. */
export interface Ref {
  id: string;
  name: string;
}

/** The stored result of a connection's last Test. */
export interface Testable {
  last_tested_at: string | null;
  last_test_ok: boolean | null;
  last_test_message: string | null;
}

export const USER_ROLES = ["admin", "member", "guest"] as const;

export type UserRole = (typeof USER_ROLES)[number];

export interface User {
  id: string;
  email: string;
  name: string;
  role: UserRole;
  household_id: string;
  /** From a paired household, signed in by their own fog. */
  visitor: boolean;
  created_at: string;
}

export interface WebauthnCredential {
  id: string;
  nickname: string | null;
  created_at: string;
  last_used_at: string | null;
}

export interface SessionResponse {
  token: string;
  user: User;
}

/** SetupController#show — whether this instance still needs its first-run
 *  wizard, and how the console signs people in. */
export interface SetupStatus {
  setup_required: boolean;
  /** Sign in with an OpenID provider (fog): offered when configured, and
   *  the only way in once Stream has proven it runs on fog. */
  signin?: { enabled: boolean; fog_only: boolean };
}

export const ACTIVITY_SEVERITIES = ["info", "warn", "error"] as const;

export type ActivitySeverity = (typeof ACTIVITY_SEVERITIES)[number];

/** What an entry is about: a type and id always, a label and console path
 *  while the subject still exists and has a page. */
export interface ActivitySubject {
  type: string;
  id: string;
  label: string | null;
  path: string | null;
}

export interface ActivityEntry {
  id: string;
  source: string;
  event: string;
  severity: ActivitySeverity;
  summary: string;
  subject_type: string | null;
  subject_id: string | null;
  subject: ActivitySubject | null;
  payload: Record<string, unknown>;
  duration_ms: number | null;
  trace_id: string | null;
  created_at: string;
}

export interface Notification {
  id: string;
  kind: string;
  icon: string | null;
  title: string;
  path: string | null;
  read_at: string | null;
  created_at: string;
}

export interface NotificationsResponse {
  unread_count: number;
  notifications: Notification[];
}

export interface MachineInfo {
  hostname: string;
  os: string;
  kernel: string;
  arch: string;
  cpus: number;
  memory_total_bytes: number | null;
  containerized: boolean;
  pid: number;
  user: string | null;
}

export interface About {
  git_sha: string;
  git_sha_short: string;
  environment: string;
  ruby_version: string;
  rails_version: string;
  postgres_version: string | null;
  time_zone: string;
  booted_at: string;
  machine: MachineInfo;
  storage: {
    state_dir: string;
    total_bytes: number | null;
    free_bytes: number | null;
  };
}

export const JOB_RUN_STATUSES = ["queued", "running", "succeeded", "failed"] as const;

export type JobRunStatus = (typeof JOB_RUN_STATUSES)[number];

export const JOB_RUN_TRIGGERS = ["manual", "system"] as const;

export type JobRunTrigger = (typeof JOB_RUN_TRIGGERS)[number];

export interface JobRun {
  id: string;
  job_key: string;
  status: JobRunStatus;
  trigger: JobRunTrigger;
  message: string | null;
  error: string | null;
  started_at: string | null;
  finished_at: string | null;
  created_at: string;
}

export interface ManagedJob {
  key: string;
  label: string;
  description: string;
  runs: JobRun[];
}

export const API_TOKEN_SCOPES = ["full", "read"] as const;

export type ApiTokenScope = (typeof API_TOKEN_SCOPES)[number];

export interface ApiToken {
  id: string;
  name: string;
  /** The first characters of the token — all that is ever shown again. */
  prefix: string;
  /** `read` may look at everything and change nothing (fog mints these). */
  scope: ApiTokenScope;
  expires_at: string | null;
  expired: boolean;
  last_used_at: string | null;
  created_at: string;
}

/** The create response: the record plus its plaintext, shown exactly once. */
export interface ApiTokenCreated extends ApiToken {
  token: string;
}

export interface TestResult {
  ok: boolean;
  message: string;
}

/** Settings › General (SettingsSerializer.general_json). */
/** What ntfy pushes to a profile's topic (app/serializers/settings_serializer.rb). */
export const NTFY_PUSHES = ["new_episodes", "new_videos", "live_reminders"] as const;

export type NtfyPush = (typeof NTFY_PUSHES)[number];

export interface NtfyTopic {
  profile_id: string;
  profile: string;
  /** null until the profile picks one in Settings › Viewing. */
  topic: string | null;
  pushes: NtfyPush[];
}

export interface GeneralSettings {
  webhook_url: string | null;
  ntfy_url: string | null;
  /** Every profile's topic, for an admin; empty for anyone else. */
  ntfy_topics: NtfyTopic[];
  max_video_transcodes: number | null;
  encoder: EncoderKind;
  default_max_video_transcodes: number;
  avx2: boolean;
  tone_mapping: string;
  optimize_automatically: boolean;
  /** Optimizing paused from the Playback page: only "now" requests encode. */
  optimize_paused: boolean;
  optimize_quiet_start_hour: number;
  optimize_quiet_end_hour: number;
  optimize_max_height: number;
  optimize_budget_gb: number;
  fetch_trailers: boolean;
  /** The household's clock (the Grid's schedules); null means the server's. */
  time_zone: string | null;
  server_time_zone: string;
  time_zones: { name: string; label: string }[];
}
