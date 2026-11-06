---
name: verify
description: How to run and drive Stream locally to verify changes end-to-end
---

# Verifying Stream changes

Rails JSON API + React SPA. The dev Postgres runs in docker on host port
5437 (`stream-db-1`). Nothing
else in the stack is required to boot — TMDB, Sonarr/Radarr and Immich are
configured in Settings and can all be absent. ffmpeg/ffprobe 7+ must be on
PATH for media work (`brew install ffmpeg`, or run inside the dev image).

## Local development (from CLAUDE.md)

```bash
docker compose up -d db          # Postgres on 5437
bin/rails db:prepare
bin/rails server -p 3003
bin/transcoder                   # owns ffmpeg for streamed playback (LISTEN/NOTIFY); without it only direct play works
npm --prefix frontend run dev    # SPA on 5177, proxies /api, /artwork and /media to 3003
bin/ci                           # everything, incl. e2e (CI runs the rest on push)
npm --prefix frontend run e2e    # Playwright against a seeded harness household (the last step of bin/ci)
```

YouTube pulls need `yt-dlp` and `deno` on PATH (`brew install yt-dlp deno`;
the image bakes both, and Settings › YouTube › Update now fetches a newer
yt-dlp into `storage/tools`). Specs stub yt-dlp and every upstream API.

ffmpeg and ffprobe (7+ — jellyfin-ffmpeg in the images; locally Homebrew's
`ffmpeg-full`, linked with `brew link --force ffmpeg-full`, since the plain
`ffmpeg` formula dropped libwebp and zimg in 9.0; Debian's 5.1 is too old,
see docs/spikes.md) must be on PATH for the media specs.
The Apple TV client is `clients/appletv` (XcodeGen; `make gen build test`,
needs Xcode's tvOS platform). A remote
transcoder is `bin/stream-transcode-worker --server … --token …` on any
machine with ffmpeg.

## Backend / API surface

```bash
docker compose up -d db
DATABASE_PORT=5437 bin/rails db:prepare
DATABASE_PORT=5437 bin/rails server -p 3003
DATABASE_PORT=5437 bin/transcoder     # streamed playback (remux/transcode); direct play works without it
```

Auth: `POST /api/v1/session` with `{"email":..,"password":..}` returns
`{"token":..}`; pass it as `Authorization: Bearer <token>`. A long-lived
token for scripts: `POST /api/v1/api_tokens {"name":"probe"}` → the
plaintext (`stream_…`) is in that one response.

Fixtures: `DATABASE_PORT=5437 bin/rails runner` against `Household.first`,
or the harness household below. Clean up with another runner when done.

Checks: before pushing, run only what covers the files you changed and let
CI run the full suite.
Ruby: `bin/rubocop <files>`, `bundle exec srb tc`,
`DATABASE_PORT=5437 bundle exec rspec <specs>`. Frontend: `npm --prefix
frontend run lint`, `npm --prefix frontend run build`, `npx --prefix frontend
vitest related --run <files>`, `bin/design-guard`. CI does not run
Playwright or `bin/check-openapi`: run the matching e2e spec for playback work
and `bin/check-openapi` when a serializer or openapi spec changed. `bin/ci`
still runs everything (rubocop, srb tc, rspec, frontend lint/build/test,
design guard, then the Playwright harness below) when you want it all.

## Frontend

`frontend/` is Vite (`npm --prefix frontend run dev` → 5177, proxying /api to
3003). Typecheck with `npm run build` (`tsc -b`, what the Docker deploy
runs) — a bare `tsc --noEmit` checks nothing against the references-only
root tsconfig.

## Browser harness (`frontend/e2e`)

Playwright drives the real SPA in Chromium — for anything a unit test cannot
see, and to look at a change rather than infer it.

```bash
npx --prefix frontend playwright install chromium   # once
cd frontend && npm run e2e          # headless, list reporter
npm run e2e:ui                      # pick and step through specs
npx playwright test e2e/smoke.spec.ts
```

`npm run e2e` boots both halves itself (Rails on 3103, Vite on 5277 — not
the dev ports, so an open dev server is left alone) and reuses whatever is
already running there. A Rails server reused from before a migration keeps
its old schema: kill whatever is on 3103 after migrating. `e2e/global-setup.ts`
also starts a `bin/transcoder` for the run (log:
`e2e/.artifacts-transcoder.log`), since streamed playback needs one. Before the first spec, `e2e/global-setup.ts` runs
`bin/rails e2e:seed` (`lib/tasks/e2e.rake`), which resets a dedicated
**"E2E Harness" household** (e2e@example.com / passwordpassword) with two
unread notifications and a real media library: fixture files copied into
`tmp/e2e-media/{movies,tv}` and read by the real scanner, prober, matcher and
frame grabber (so the seed needs ffmpeg on PATH). Heat, Alien and Primer
(the MKV Phase 1 refuses) plus two Severance episodes; the WebM copies are
what Playwright's Chromium can play, since it ships without H.264. Your own
dev household is never read or written. `bin/rails e2e:clean` removes it.

Specs import `./support/harness`, whose `test` fixture signs in over the API
once per run (shared through `e2e/.artifacts-session.json`, so a failure's
worker restart doesn't sign in again and trip the rate limit) and plants
`stream_api_token` + `stream_user` in localStorage (AuthProvider needs both).
Under `E2E=1` the Rails server runs jobs in-process (`:async`), so scans and
webhooks finish without `bin/jobs`.

Projects: `chromium` reads the seed as it is; `chrome` and `webkit` play the
corpus, and `chrome` also streams the three-minute Long Take (a far seek
resumed on a second device, a transcoder restart — `e2e/support/transcoder.ts` owns its pid;
seeking back and playing on through what was buffered, `seams.spec.ts`; and on
a Grid channel, `live-streaming.spec.ts`). Long Take is made like a real
film — B-frames, uneven keyframes — and a strip across the top of its picture
says what second it is: `e2e/support/film.ts` reads the frame on screen, to
hold it against the player's clock. `changes`
runs last and changes things (files moved and arriving by Sonarr's webhook,
a library added, an invite redeemed, a passkey enrolled as `localhost`).

**Playback suite** (`e2e/playback.spec.ts`): every file in the seed's Corpus
library must play, in real Chrome (`channel: "chrome"`) and in Playwright's
WebKit (Safari's engine) — the Phase 2 exit. Playwright's own Chromium has
no H.264 or AAC, so it runs only the UI suite.

```bash
npx playwright install webkit             # once
npx playwright test --project=chrome      # needs Google Chrome installed
npx playwright test --project=webkit
```

**To look at something:** add a temporary spec that clicks its way to the
state and calls `page.screenshot({ path })`, run it, read the PNG, delete the
spec. Keep checked-in specs asserting behaviour; no `toHaveScreenshot`
baselines — they rot across machines.

## Gotchas

- CI does not run e2e (it needs browsers and a database); run the
  relevant spec by hand before pushing player or frontend flow work.
- Provider and integration calls are webmock-stubbed in specs; a real run
  against the network happens only through the app.
- Media specs run ffmpeg against the tiny generated corpus in
  `spec/fixtures/media` (`bin/media-fixtures` regenerates it); never commit a
  real film.
