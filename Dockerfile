# syntax=docker/dockerfile:1
# One image serves web, worker, and the release (migration) phase — fog runs
# them as different commands against the same image.

# ---- Stage 1: build the console SPA -----------------------------------------
FROM node:24-slim AS console_build
WORKDIR /build
COPY frontend/package.json frontend/package-lock.json ./frontend/
RUN cd frontend && npm ci
COPY frontend ./frontend
RUN cd frontend && npm run build

# ---- Stage 2: base runtime ---------------------------------------------------
FROM ruby:3.4.2-slim AS base
WORKDIR /rails

# HTTP_WRITE_TIMEOUT=0: Thruster's default (30 s) cuts every response that
# takes longer to deliver — which is every direct-play stream of a film
# (docs/spikes.md › Spike A).
ENV RAILS_ENV=production \
    PATH="/usr/lib/jellyfin-ffmpeg:${PATH}" \
    HTTP_WRITE_TIMEOUT=0 \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development

# zstd unpacks fog-backup/1 file components (tar --zstd) when an older
# artifact is restored; fog-backup/2 writes plain tars. Artwork is rendered
# by ffmpeg too (libwebp), so there is no separate image library.
#
# ffmpeg is jellyfin-ffmpeg, not Debian's: bookworm ships 5.1, whose fMP4
# muxer rebases every run's timestamps to zero, so a remux restarted for a
# seek can't continue the timeline (docs/spikes.md › Spike B). Jellyfin's 7.x
# build writes absolute tfdt with movflags=+frag_discont, carries the Intel
# iHD/QSV stack Intel iGPUs need, and includes the chromaprint muxer used
# for intro detection, so there is no separate fpcalc.
#
# postgresql-client comes from PGDG, not Debian's default package: bookworm's
# "postgresql-client" pulls v15, but the fleet standard is Postgres 18
# (fog's managed cluster, internal/pg/pg.go; see fog docs/postgres-18-proposal.md).
# A pg_dump older than the server it's dumping refuses to run at all, which
# silently aborts every pre-update backup (FogBackup::Producer) and the
# update along with it. Bump the pin when the fleet moves majors.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl ca-certificates gnupg && \
    install -d /usr/share/postgresql-common/pgdg && \
    curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc && \
    echo 'deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main' > /etc/apt/sources.list.d/pgdg.list && \
    install -d /etc/apt/keyrings && \
    curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor -o /etc/apt/keyrings/jellyfin.gpg && \
    echo 'deb [signed-by=/etc/apt/keyrings/jellyfin.gpg] https://repo.jellyfin.org/debian bookworm main' > /etc/apt/sources.list.d/jellyfin.list && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      libjemalloc2 postgresql-client-18 zstd \
      jellyfin-ffmpeg7 && \
    rm -rf /var/lib/apt/lists/*

# yt-dlp pulls tracked YouTube channels (PROPOSAL §5.4); this baked copy
# is the floor, and UpdateYtDlpJob keeps a newer one in storage/tools that
# wins. YouTube extraction now needs a JavaScript runtime, which yt-dlp
# finds as deno on PATH. Both are single static binaries.
ARG TARGETARCH
RUN apt-get update -qq && apt-get install --no-install-recommends -y unzip && \
    case "${TARGETARCH}" in arm64) ytdlp=yt-dlp_linux_aarch64; deno=aarch64-unknown-linux-gnu ;; *) ytdlp=yt-dlp_linux; deno=x86_64-unknown-linux-gnu ;; esac && \
    curl -fsSL -o /usr/local/bin/yt-dlp "https://github.com/yt-dlp/yt-dlp/releases/latest/download/${ytdlp}" && \
    chmod 755 /usr/local/bin/yt-dlp && \
    curl -fsSL -o /tmp/deno.zip "https://github.com/denoland/deno/releases/latest/download/deno-${deno}.zip" && \
    unzip -q /tmp/deno.zip -d /usr/local/bin && rm /tmp/deno.zip && \
    apt-get purge -y unzip && rm -rf /var/lib/apt/lists/*

# ---- Stage 3: gems -----------------------------------------------------------
FROM base AS build
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev pkg-config libyaml-dev && \
    rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./
# Vendored path gems (flare, fog-client) must exist when bundle install
# resolves the Gemfile — COPY the directory itself, not a glob: `COPY vendor/*
# ./vendor/` flattens each subdirectory's contents.
COPY vendor ./vendor
RUN bundle install && \
    rm -rf ~/.bundle "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

COPY . .
COPY --from=console_build /build/public /rails/public
RUN bundle exec bootsnap precompile app/ lib/

# fog stamps the commit via the GIT_REV build arg; StreamVersion falls back to
# this file when GIT_SHA isn't in env (surfaced at /api/v1/about).
ARG GIT_REV=unknown
RUN echo "${GIT_REV}" > /rails/REVISION

# ---- Stage 4: final ----------------------------------------------------------
FROM base
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# Non-root; uid 1000 matches the `owner` on fog's managed volumes, so the
# storage and cache volumes need no chown dance. Media mounts are read-only.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p /cache /media /rails/storage /rails/log /rails/tmp && \
    chown -R rails:rails /rails/log /rails/tmp /rails/storage /cache
USER 1000:1000

EXPOSE 80
# The entrypoint is the restore-on-boot guard (fog-backup/1 and /2): a staged, armed
# artifact is restored before any process serves.
ENTRYPOINT ["./bin/docker-entrypoint"]
CMD ["./bin/thrust", "./bin/rails", "server"]
