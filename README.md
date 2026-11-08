# Stream

A self-hosted video player for the household: movies, shows, YouTube
channels and home videos, streamed from the home network to the browser at
original quality whenever the browser can take it. An evolution of Plex and
Jellyfin, with YouTube's grammar for everything that isn't a film or a
series.

Stream is a player, not an acquirer. It reads the folders Sonarr, Radarr
or anything else put down, never writes into them, and picks the cheapest
way to play each file: direct play, then remux, then an audio-only
transcode, then a pre-made optimized version, and a video transcode only as
a last resort. The one source it pulls itself is YouTube, through yt-dlp,
into a folder you choose.

There is also a native Apple TV client in [`clients/appletv`](clients/appletv).

## Running it

Stream is built to run on [fog](https://github.com/fogapp/fog), a
self-hosting platform for a household's apps. `stream.fog.yaml` is its app
manifest: fog provides Postgres, the secrets, the media mounts, sign-in and
backups, and runs the release step before each deploy. `fog.yaml` holds what
fog shows on first run.

Off fog, Stream is an ordinary Rails app in a Docker image (`Dockerfile`):

- **Processes:** the web server (the image's default command), the job
  worker (`bin/jobs`) and the transcoder (`bin/transcoder`, which owns
  ffmpeg for streamed playback; without it only direct play works).
- **Database:** Postgres 18 with `pg_trgm`, `citext`, `pgcrypto`,
  `unaccent` and `vector`; three databases (`stream_production`, `_cache`,
  `_queue`), reached through `DATABASE_HOST`, `DATABASE_PORT`,
  `DATABASE_USER`, `DATABASE_PASSWORD`, `DATABASE_NAME`. Run
  `bin/rails db:prepare` before starting a new release; migrations never run
  at boot.
- **Secrets:** `SECRET_KEY_BASE`, `AR_ENCRYPTION_PRIMARY_KEY`,
  `AR_ENCRYPTION_DETERMINISTIC_KEY`, `AR_ENCRYPTION_KEY_DERIVATION_SALT` and
  `STREAM_TOKEN_KEY` (signs media URLs). Production refuses to boot without
  them.
- **Other environment:** `STREAM_HOST` (the public hostname),
  `STREAM_CACHE_DIR` (transcode segments; regenerable), optionally
  `TIME_ZONE` (default `America/Los_Angeles`; Settings › General can pick
  another). Sign-in through any OpenID Connect provider with
  `OIDC_ISSUER`, `OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET`; without them,
  people sign in with email and password or a passkey.
- **Volumes:** `/rails/storage` (artwork, trickplay, extracted subtitles —
  back this up), the cache directory, and your media folders mounted
  read-only (plus one writable folder if you want YouTube downloads).

Everything else — which folder is which library, TMDB, Sonarr/Radarr,
Immich, OpenSubtitles, Trakt, a Plex server to migrate from — is configured
in the app under Settings, never by environment variable. Bring your own API
keys for those services.

A fresh instance has no users: the first person to open it runs the setup
wizard and becomes its admin, so don't expose a new install before you've
done that. [`ACCESS.md`](ACCESS.md) lists every way in and how each is
authenticated.

## Development

Requirements: Ruby 3.4, Node 24, Docker (for Postgres), and ffmpeg/ffprobe
7 or newer on `PATH` (jellyfin-ffmpeg in the images; Homebrew's
`ffmpeg-full` on a Mac). YouTube needs `yt-dlp` and `deno`.

```bash
docker compose up -d db                  # Postgres on 5437
DATABASE_PORT=5437 bin/rails db:prepare
DATABASE_PORT=5437 bin/rails server -p 3003
DATABASE_PORT=5437 bin/transcoder        # streamed playback
npm --prefix frontend ci
npm --prefix frontend run dev            # http://localhost:5177
bin/ci                                   # every check, then the Playwright harness
```

`bin/media-fixtures` regenerates the synthetic test media.

## Documentation

- [`docs/PROPOSAL.md`](docs/PROPOSAL.md) — the design: north star,
  architecture and phased plan.
- [`CLAUDE.md`](CLAUDE.md) and [`frontend/CLAUDE.md`](frontend/CLAUDE.md) —
  house conventions, enforced by CI.
- [`ACCESS.md`](ACCESS.md) — every surface and credential.
- `/api-docs` on a running instance — the OpenAPI document for native
  clients.
- `docs/` also holds the performance work, the Apple TV playback
  investigation, and the Phase 0 spikes the playback engine was built on.

Stack: Rails 8.1 API (Sorbet strict, Solid Queue, Postgres 18) + React 19
SPA (Vite, Tailwind v4, TanStack Query), ffmpeg for media.

## License

Copyright (C) 2026 Matthew Werner

Stream is free software: you can redistribute it and/or modify it under the
terms of the GNU Affero General Public License as published by the Free
Software Foundation, version 3 (AGPL-3.0-only). See [LICENSE](LICENSE) for
the full text. That includes the Apple TV app in `clients/appletv`.

The client libraries vendored under `vendor/gems/` (`fog-client` and `flare`
from Fog, `glass` from Glass) are under the MIT License, each with its own
`LICENSE`.

The names and logos (Fog, fogapp, Fin, Stream and Glass) are trademarks,
which the licenses don't cover. You may use them to refer to the software,
and run or redistribute it unmodified under them; a modified version you
distribute or offer to others needs its own name. See [TRADEMARKS.md](TRADEMARKS.md).

Issues are welcome; pull requests aren't accepted for now. See
[CONTRIBUTING.md](CONTRIBUTING.md).
