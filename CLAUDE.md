# Stream — house conventions

The **household's video player**: it reads the video already on the network
(movies, shows, YouTube channels it pulls itself, home videos from Immich)
and plays it in the browser instantly, at original quality whenever the
browser can take it. Full design in [`docs/PROPOSAL.md`](docs/PROPOSAL.md) —
read §0 (north star) and §11 (phases) before adding features.

Rails 8.1 JSON API (`app/`) + React SPA (`frontend/`), scaffolded from hook.
Everything below is enforced by CI (`bin/ci`: rubocop incl.
`rubocop/stream_cops.rb`, `srb tc`, rspec, frontend lint/build/test,
`bin/design-guard`) or by review.

## Stream is a player, not an acquirer

Sonarr, Radarr and hook own acquisition; Stream reads what they put down and
listens to their webhooks. The one source Stream pulls itself is YouTube
(PROPOSAL §5.4). Search may *ask* hook for a film or show on the person's
behalf (`Hook::Client`, PROPOSAL §7.9); hook decides how to get it. Music (Navidrome), photos (Immich) and broadcast TV are
out; Grid is channels scheduled from the library (PROPOSAL §7.7).

## Media invariants (the expensive lessons, in advance)

1. **Never write into a library root.** Media folders are fog `Content`
   (a NAS share). Artwork, trickplay, extracted subtitles and NFO edits
   live in `storage`; transcode segments and optimized versions in `cache`
   (they can always be made again). The one exception is
   YouTube (PROPOSAL §5.4): yt-dlp downloads into the single folder chosen
   in Settings › YouTube, and keep-last retention deletes only rows in
   `youtube_downloads` — files Stream fetched itself, inside that folder.
2. **Identity is content, not path.** A `MediaFile` is its fingerprint; a
   move carries watch state, markers and analysis with it. A vanished file is
   `missing`, never deleted on sight.
3. **Direct first.** The decision engine picks the cheapest path per stream:
   direct play → remux → audio transcode → optimized version → video
   transcode. A video transcode is a last resort and always carries its
   reason. Where it runs (here, or a remote transcoder) is
   `Playback::Placement`'s call, and a run starts through `Playback::Runner`
   either way.
4. **Probe once, decide from rows.** ffprobe runs at scan time; the decision
   engine reads `MediaStream` rows and never probes at play time.
5. **Every analysis step leaves an `AnalysisRun`.** Never stamp success on
   failure; failures record `last_error` and surface in Needs attention.
   Silent failure is the enemy.
6. **ffmpeg is argv-only** through `ToolRunner`/`MediaTool`, with
   `-protocol_whitelist file,pipe`. No shell strings, ever. The one other
   input is a remote transcoder reading `/media/n/<run token>/source`
   (`FfmpegArgs::Input.remote`, `http,https,tcp,tls`). yt-dlp is argv-only
   too, and only ever handed a URL `Youtube::Urls` rebuilt from a validated id.
7. **Bytes go through Thruster.** Rails authorizes and answers with
   `X-Sendfile`; a Puma thread is never held for the length of a movie.
8. **Fan-out jobs only fan out**, so every executing job carries a real
   `limits_concurrency` key (per library, per file).

## Sorbet

- Every file in `app/` is `# typed: strict` (rubocop enforces the sigil).
  Concerns are the documented exception — `HouseholdScoped` is DSL-driven,
  uses `requires_ancestor` + `T.bind`, and `T.unsafe` only where a column
  lives on the *including* model.
- Generated RBIs come from custom compilers in `sorbet/tapioca/compilers/`
  (typed-enum attributes, controller `finds`). After adding an
  `attribute :x, SomeEnum` or a `finds :thing`, run `bin/tapioca dsl <Const>`.
  Never hand-write shims for generated methods.
- `Current` is deliberately untyped (CurrentAttributes is a dynamic
  boundary). Use `current_user!` / `current_household!` — the typed
  re-assertion — everywhere else. They are `protected`, not `private`,
  because `finds` lambdas call them with an explicit receiver.

## Enums

Closed vocabularies are `T::Enum`s wired with `ApplicationRecord.attribute`,
nested in the owning model, including `ApplicationEnum`. Columns stay strings
on disk. Query with `Enum::Value.serialize`; parse params with
`try_deserialize`; never bridge two enums with `X.deserialize(y.serialize)`
(cop-enforced) — write an exhaustive mapping with `T.absurd`.

## Controllers, serializers, services

- Controllers are thin: params in, service/serializer out. Use
  `BaseController` helpers — `finds`, `paginate`, `render_errors`,
  `bool_param`, `parse_param_time/date`, `require_admin!`. The only error
  envelope is `{ errors: [...] }` (cop-enforced); `{ ok:, error: }` is
  reserved for integration `test_connection`.
- Upstream HTTP goes through `UpstreamHttpClient` (timeouts, circuit breaker,
  typed errors). Raw `Net::HTTP` is cop-banned outside it. Sibling apps on the
  fog network (Sonarr, Radarr, Immich, Whisper) are private addresses by
  design — their clients override `allow_private_addresses?` with the cop's
  written-reason disable.
- Every JSON shape lives in `app/serializers/`.
- What a native client needs is documented by running it in
  `spec/requests/openapi` (rswag); `bin/rails rswag:specs:swaggerize`
  regenerates `swagger/v1/openapi.yaml` (served at `/api-docs`), and
  `bin/check-openapi` in `bin/ci` fails when it's stale.
- What a profile may see is decided in one place, `Viewing::Access`
  (libraries, rating ceiling, curated tags), from `Current.profile`. Any new
  catalog query or title lookup goes through it — MCP tools included, which
  run `as_profile`.
- Token-in-the-path surfaces sign one row each and live outside `/api`:
  `/media/s` (a playback session), `/media/d` (an offline download),
  `/media/n` (a remote transcoder's run), `/fog/compute/runs` (a run on one
  of fog's machines, reached through fog's data route). `/mcp` and
  `/api/v1/transcoder` authenticate an API token and a node token, and
  `/fog/compute/transcoders` fog's FOG_API_TOKEN, never a login session.

## Frontend

- `frontend/CLAUDE.md` has the non-negotiables. Cardinal rule: **semantic
  color tokens only** (`bin/design-guard` greps `.ts` and `.tsx` in CI).
  The theme is dark-first; light is the token override.
- Build `ui/` primitives before pages. A failed query never renders as an
  empty list — use `LoadingState` / `ErrorState` / `EmptyState`.
- Query keys come from `lib/queryKeys.ts`; `api.get<T>` performs no runtime
  validation, so `src/types` must track the serializers.
- Closed vocabularies are derived unions (`as const` list → union → keyed
  maps) mirroring the backend enums.

## Configuration belongs in the UI

1. **External connectivity is configured in-app, never by env var.** TMDB
   keys, Sonarr/Radarr, Immich, OpenSubtitles, a Plex server to migrate from —
   entered in Settings, stored encrypted (`encrypts`), never serialized back
   to the client, validated by a `test_connection` action.
2. **Paths are configured in-app too, and never assumed.** Which mounted
   folder is which library is Settings › Libraries, validated with
   `StorageLocation` before saving. The fog manifest only provides mounts.

Env vars are for what fog must inject to boot: database connection,
encryption keys, `STREAM_TOKEN_KEY`, `GIT_SHA`, `STREAM_HOST`,
`STREAM_CACHE_DIR` — and what a fog-integration/1 offer sets when an app is
connected on fog's Integrations tab (`LUCID_*`, `HOOK_URL`/`HOOK_API_TOKEN`).
Nothing a person would want to change afterwards.

## Deployment

fog-managed git app (`stream.fog.yaml`; `fog.yaml` carries the
getting-started text). Consequences:

- **Migrations run in the release phase only, never at boot** — fog overlaps
  two web replicas during a blue-green swap.
- `/up` must be unauthenticated, answer <500 within 120s of boot, and not
  depend on the worker or the transcoder.
- Playback session state lives in Postgres and segments on the shared
  `cache` volume, so a web swap never drops a playing session.

## Local development

The Apple TV client (`clients/appletv`) decodes fixtures captured from the
e2e harness: refresh them when a serializer it reads changes.

`.claude/skills/verify/SKILL.md` is the runbook for booting, seeding, ports,
tool requirements (ffmpeg, yt-dlp), and looking at a change in the browser.
