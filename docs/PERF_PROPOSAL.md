# Stream — Playback Performance Proposal

*v0.3, 2026-09-29. Status: PRs 1–6 built and committed (§3, §3.1); P18 and P19 left at the checkpoint; production numbers (§6) wait on a deploy. A code audit of the
playback path against four reported symptoms, and the changes that fix
them. Companion to [PROPOSAL.md](PROPOSAL.md) §6 (the playback design) and
§6.4 (the targets); measurements in [spikes.md](spikes.md) › B are the
baseline the design was built on. Paths are relative to the repo root.*

## 0. The symptoms

1. Pressing Play takes a long time before the video starts.
2. Changing channels in Grid takes too long.
3. When a video starts, the audio sometimes comes in a beat after the picture.
4. Seeking to another point in the timeline takes a long time to show a frame.

The proposal's targets (§6.4) are 800 ms to first frame for direct play,
1.5 s for a remux, 3 s for a video transcode, and 400–800 ms for a seek.
Spike B measured a warm remux at 300–750 ms and a far seek at 200–560 ms on
a ten-minute test file. Production does not feel like that, and the audit
explains why: the spike measured ffmpeg and the player; the app around them
has grown a lot of work in between.

## 1. What is actually slow

Every symptom traces to a handful of structural causes, not one bug.

### 1.1 The Play request does too much before the token exists

`POST /api/v1/playback_sessions`
(`app/controllers/api/v1/playback_sessions_controller.rb`) runs, in order:

- `Viewing::Access.allows?` twice for a Grid tune-in (station, then
  playable); for a restricted profile each is the whole-household "barred
  airings" anti-join (`app/services/viewing/access.rb:74-92`).
- `upsert_device`: a `save!` that writes the row on every Play even when
  nothing changed.
- `Playback::Placement.node_for_video`: transcoder-node queries and a
  `COUNT` per node, run before the method is known, so direct play and remux
  pay for it too. It calls `Encoders.kind`, which on an hourly cache miss
  runs a **20 s-timeout ffmpeg hardware probe inside the Puma thread**
  (`app/services/playback/encoders.rb:37,79-88`) whenever
  `/dev/dri/renderD128` exists.
- `choose`: loads every probed file of the playable with the full row,
  including the `keyframes int[]` and `probe jsonb` columns.
- `ensure_keyframes` (`:178-187`): for a streamed copy of a file with no
  keyframe index, reads the container index and, failing that, runs
  `Media::Keyframes::PacketScan` **synchronously in the request**. The scan
  reads the whole file over the NAS with a timeout of 120 s per GB. Its own
  comment says minutes for a 30 GB remux. It also skips `AnalysisRun`, so a
  failure surfaces as a 500 rather than in Needs attention (invariant 5).
- `prewarm`: `SegmentPlan.for(session)` reloads the media file and sorts the
  whole keyframe array. Cheap by comparison; the NOTIFY itself is free.
- `PlaybackSessionSerializer.session_json`
  (`app/serializers/playback_session_serializer.rb:11-51`), the heaviest
  part: `Subtitles::Tracks.for(file)` calls `sidecars`, which does
  **`Dir.children` on the media folder over SMB/NFS**
  (`app/services/subtitles/tracks.rb:97-116`), plus two storage-directory
  listings (downloaded subtitles, fonts), markers, show preference,
  trickplay, profile, airing and station, each its own query.

None of this is needed to start the first byte moving. The token, the URLs,
the method and the resume position are.

### 1.2 Everything after the POST is serial

From the click (`frontend/src/components/viewing/PlayButton.tsx:25`):

1. `navigate('/watch/…')`, then `Watch` mounts, then a `useEffect` calls
   `play()` (`frontend/src/pages/Watch.tsx:27-31`). The POST starts one
   commit after the route change, not on the click.
2. The POST above.
3. `<Player>` mounts, renders twice (ref → state), then an effect calls
   `attachSource`, and **only now** `import("hls.js/light")` starts
   (`frontend/src/components/player/source.ts:36`). The chunk is 359 KB and
   nothing preloads it (`frontend/index.html`, `vite.config.ts`).
4. hls.js fetches, strictly in sequence: `hls/index.m3u8` (the master, since
   any copied source over ~540p gets an ABR ladder,
   `app/services/playback/variants.rb`), `hls/v0/index.m3u8`, `hls/v0/init.mp4`
   (**Rails blocks until ffmpeg has written it**), `hls/v0/seg-0.m4s`
   (**Rails blocks until every GOP of the segment exists, then copies them
   into one file on the Puma thread**), then appends and plays.

Four round trips before a byte of video, two of them held open by the
transcoder. On Safari the first render has `nativeHls === false` because the
element ref hasn't landed, so hls.js is imported and attached, then torn down
and native HLS attached (`frontend/src/components/player/Player.tsx:252-253`).

### 1.3 The first byte needs a full six-second segment

`Playback::SegmentPlan` (`app/services/playback/segment_plan.rb`) cuts
~6 s segments (`TARGET_MS = 6_000`). `Playback::Segments#segment`
(`app/services/playback/segments.rb:72-79`) waits for every GOP in the
segment, then `join`s them (`:127-135`) before answering. Converted video is
forced to a 6 s keyframe grid (`app/services/playback/ffmpeg_args.rb:99`),
and `-hls_flags temp_file` means a fragment appears only when the *next*
keyframe arrives. So:

- a video transcode encodes 6 s before the first frame can be served
  (1–1.5 s at the 4.6–7× measured in Phase 0, linearly worse for 4K or HDR
  tone-mapping in software);
- a seek into un-produced territory pays the same again;
- a remux waits for as many source GOPs as fit in 6 s, and copies tens of
  megabytes on a web thread.

### 1.4 Readiness is polled, not signalled

`Segments#await` (`segments.rb:103-113`) sleeps 25 ms between checks for up
to 20 s, and **every iteration runs `failure`, a database `pick`**
(`:119-122`): ~40 queries per second per waiting thread. Puma runs one
process with eight threads (`config/puma.rb`, `stream.fog.yaml`), shared
with the whole API. A few viewers seeking at once pin the pool, and API
calls queue behind sleeping threads. Each segment also does a
`bytes_sent` UPDATE (`app/controllers/media_controller.rb:164-175`), and
nothing sets `Cache-Control` on init or segments.

The transcoder (`bin/transcoder`, `app/services/playback/supervisor.rb`) is
a single thread that answers NOTIFYs serially. Each request does three or
four queries, rebuilds the full `SegmentPlan` from the keyframe array, walks
the ready fragments one `File.file?` at a time (`close_enough?`, `:101-107`),
and every 5 s the same thread runs a `sweep` that globs every session
directory on the cache volume (`:186-210`).

### 1.5 Seeks are not coalesced anywhere

- The seek bar commits `currentTime` on `pointerdown` and on **every
  `pointermove` while dragging** (`frontend/src/components/player/SeekBar.tsx:56-64`).
  Keyboard seeks fire per keypress.
- Each target more than `AHEAD = 4` GOPs past the run's frontier
  (`supervisor.rb:17,60`) does `Process.kill("-KILL")` then a **blocking
  `waitpid`** on the transcoder's only thread (`app/services/playback/runner.rb:76-77`),
  then spawns a new ffmpeg that opens the file over the NAS and seeks.
- A target 1–4 GOPs ahead is *waited for* instead. After the first 30 s a
  run is throttled to 2× real time (`-readrate 2 -readrate_initial_burst 30`),
  so that wait is up to ~12 s of wall time on converted video.
- Rails cannot see the browser abort a request, so every abandoned segment
  request from a scrub holds its thread for the full 20 s.

### 1.6 Grid neighbours are full sessions

`useChannelDeck` (`frontend/src/components/live/useChannelDeck.ts`) keeps a
standby session for the channel above, below and last. Each is its own
`POST /playback_sessions` (the full cost of §1.1, including
`ensure_keyframes` for the airing's file), its own ffmpeg run, its own
hls.js instance buffering 30 s, and a `currentTime = liveAt` nudge every 8 s
(`:259-275`) that can itself restart ffmpeg. Channels whose file needs a
video transcode are refused as standby (`playback_sessions_controller.rb:51-53`)
and are released when switched away from, so flipping to one is always a
cold start. Every flip creates at least one new neighbour session. The
guide preview (`frontend/src/components/live/GuidePreview.tsx`) creates
and destroys a session and an ffmpeg per focused row.

The server never ends the previous session; the client parks it with
`standby` or `DELETE`s it. `PlaybackSession::IDLE_AFTER` is defined and
referenced nowhere; a session whose client vanished keeps its budget slot
for 2 minutes and its token for 6 hours.

### 1.7 Audio is re-routed after playback has started

`useAudioLevelling` (`frontend/src/components/player/audio.ts:89-124`) builds
`AudioContext → createMediaElementSource(video) → gain (→ compressor)` on
mount, after an `await context.resume()`. Autoplay has already begun by the
time the promise settles, so the element's output is re-routed a few frames
in. If the context was suspended (no activation yet), it retries on the
`play` event, re-routing mid-play. Chromium produces a short silence at the
reroute. This is the most likely source of symptom 3, and it only affects
non-Safari browsers, which matches "sometimes".

A second candidate: `Cache.init_ready?` is "file exists and size > 0"
(`app/services/playback/cache.rb:37`). With `+delay_moov` (any AC-3 or
E-AC-3 audio) ffmpeg writes `init.mp4` in place, not through `temp_file`,
so a half-written init can be served; hls.js then recovers with
`recoverMediaError`, which is a visible restart.

For copied audio, `-ss` before `-i` drops the audio packets that straddle
the keyframe, so the first fragment's audio starts up to one audio frame
after its video. That is 32 ms for AC-3, not a beat, but it adds to
whatever the player has to bridge.

## 2. The changes

Ordered by impact within each group. Starred items change the architecture
rather than tune it. Each item names the code it touches.

### 2.0 Measure first

**P1. Time-to-first-frame breakdown in playback events.** The player stamps
POST sent, session received, manifest loaded, init loaded, first segment
loaded and first frame painted, and sends them through the existing
`events_url` as one `start` event with a `timings` detail. Show the
breakdown on Playback decisions and in the stats overlay. Add a Playwright
test in `frontend/e2e/streaming.spec.ts` that asserts the §6.4 targets
against the harness for direct play, remux and transcode, and a far seek.
Nothing below can be called done without this.

### 2.1 Make the Play request instant

**P2. Never scan keyframes in the request.** `ensure_keyframes` reads the
container index only (Matroska Cues, MP4 `stss`: a few KB). When there is
none, it enqueues `IndexKeyframesJob` at the front of the `heavy` queue and
records an `AnalysisRun`, and the session starts in an *event* mode: the
run cuts at ffmpeg's own keyframes (`-hls_time` on a short target),
`Segments#playlist` serves `#EXT-X-PLAYLIST-TYPE:EVENT` built from the
fragments that exist, and the plan is upgraded to the exact VOD playlist
once the index lands (hls.js reloads an EVENT playlist on its own). Until
event mode exists, the minimum is: enqueue the job and answer 409 with a
"getting this ready" message rather than hold the thread.

**P3. Two-phase session.** `create` returns only what the player needs to
start: id, method, token URLs, resume position, duration, frame rate, the
decision summary. A new `GET /api/v1/playback_sessions/:id/details` returns
the rest (subtitles, fonts, chapters, markers, skip, next up, trickplay,
SponsorBlock, loudness) and the player fetches it in parallel with the
manifest. Persist the sidecar subtitle list at scan time and on hook's
webhooks, in a jsonb column on `media_files` or a `subtitle_tracks` table,
so `Subtitles::Tracks.sidecars` never lists a NAS directory on the play
path. The OpenAPI spec and the tvOS fixtures change with it.

**P4. Trim the hot-path loads.** `MediaFile.ignored_columns = [:keyframes,
:probe]`, with explicit `select` or a `with_keyframes` scope where they are
needed (`Decision#codec_tag`, `SegmentPlan.for`, `KeyframeIndex`). Memoize
the built `SegmentPlan` per session in process memory and `Rails.cache`,
keyed by session id plus the file's `updated_at`, on web and transcoder
alike. Today every `init`, `seg-N` and NOTIFY rebuilds it.

**P5. Decide first, place second.** Run `Decision` with the local encoder's
`max_height`, and only when the method is a video transcode ask
`Placement` for a node (re-deciding if the node allows a taller picture).
Move the encoder probe out of the web tier: the transcoder heartbeat writes
its `Encoders::Kind` to an `AppSetting`-style row and the web reads that.
Write the device row only when capabilities or name changed; bump
`last_seen_at` with `update_columns` at most every few minutes. Check
`Viewing::Access` once per tune-in.

### 2.2 Overlap the startup chain in the browser

**P6. Start the session on the click.** `PlayButton` POSTs on `pointerdown`
and stores the promise in `prefetchedSessions`
(`frontend/src/hooks/usePlayback.tsx:348-350`), which `play()` already
consumes. Navigation and the POST run in parallel; `Watch` no longer waits
on an effect to start.

**P7. Preload the player.** `<link rel="modulepreload">` for the hls.js,
JASSUB and libpgs chunks in `frontend/index.html`, or `import()` them on
`requestIdleCallback` after first paint. Add `preload="auto"` to the VOD
`<video>`.

**P8. One playlist on the LAN.** Serve the master playlist with the ABR
ladder only when the client asks (`abr: true` in the POST, set for mobile
or off-LAN clients). Otherwise `hls/index.m3u8` is the media playlist and
`hls.currentLevel` is pinned. This removes a round trip and, more
importantly, stops a slow transcoder from looking like a slow network: a
segment that took 15 s to produce reads as 1 Mb/s to hls.js's bandwidth
estimator, which drops a level and **spawns a second ffmpeg for the
variant** on an already busy box.

**P9. Small player fixes.** Fix the Safari first-render double attach
(`nativeHls` is false until the element ref lands; compute it from
`canPlayType` on a module-level probe instead). Call `element.play()`
explicitly with a muted fallback on `NotAllowedError` for every kind, as
the `autoplay_videos` path already does. Drop the redundant `currentTime =
from` in `onLoadedMetadata` for HLS sources (hls.js already honours
`startPosition`). Stop `captureStill` drawing a canvas on the main thread
every 10 s tick; do it on pause and unmount only.

### 2.3 First byte equals first GOP

**★ P10. Segment equals GOP for copied video, 2 s grid for converted
video.** Drop the 6 s target in `SegmentPlan`. For remux and audio
transcode every planned segment is one GOP, so the segment file *is* the
fragment ffmpeg wrote: `Segments#segment` serves `gop-N.m4s` directly and
`join` is deleted. For transcodes, `force_key_frames` every 2 s, so the
first frame needs 2 s of encoding rather than 6 and a seek lands within
2 s. Variants keep one GOP per segment as now. Playlists get longer (a
two-hour film at a 2 s GOP is 3,600 lines, ~100 KB), which is nothing on a
LAN; hls.js and Safari handle sub-second fragments. `target_duration`
becomes the longest GOP, which for the odd 20 s GOP in a stills-heavy
source is what it is.

**P11. Signal readiness instead of polling.** The transcoder issues
`NOTIFY stream_ready, '<session>:<gop>'` after each rename into place (it
sees the rename because it owns the run; an inotify watch on the session
directory is the alternative that also covers remote uploads). Each Puma
process holds one `LISTEN` connection on a thread that fans out to waiting
requests through a condition variable keyed by session and GOP.
`Segments#await` becomes a wait on that with a timeout; no 25 ms sleep, no
query per iteration. Keep a 1 s check of `transcode_error` and session
state as the safety net.

**P12. Init atomicity.** `Cache.init_ready?` also requires the run's first
GOP file to exist. ffmpeg finishes writing the init before it renames the
first fragment, so this guarantees a complete init even with
`delay_moov`.

**P13. Take waiting off the API's threads.** Add a second web process to
`stream.fog.yaml` that serves only `/media` (a Puma with 32 threads;
waiting threads are cheap) so API calls never queue behind held segment
requests. If fog can't route by path yet, `WEB_CONCURRENCY=2` and
`RAILS_MAX_THREADS=16` is the fallback. Replace the per-segment
`bytes_sent` UPDATE with an in-memory counter flushed by the 15 s `touch`.
Add `Cache-Control: private, max-age=21600, immutable` on init and
segments; the path is unique per session so it can never serve the wrong
bytes.

### 2.4 Seeking

**P14. Commit seeks on release.** During a drag the seek bar shows the
trickplay frame and the time only; `currentTime` is set on `pointerup`.
Keyboard and remote seeks are trailing-throttled at ~150 ms so a held
arrow key issues one seek, not thirty. This alone removes the restart
storm.

**P15. Coalesce and de-block restarts in the transcoder.** `Supervisor`
debounces requests per session for ~100 ms and acts on the last one.
`Runner.stop` sends SIGTERM, then SIGKILL after a short grace, from a
reaper thread; the NOTIFY loop never calls `waitpid`. The new run is
spawned before the old one is reaped, since fragments are named by GOP and
`temp_file` makes the overlap safe.

**P16. Decide restart by time, not GOP count.** Replace `AHEAD = 4` with an
estimate: from the frontier, the run's throttle (2× after the burst, disk
speed within it) and the GOP durations from the plan, compute when the run
reaches the target. Restart if that is more than ~1 s away. Today a
throttled run is waited on for up to 12 s.

**P17. Move the sweep off the hot loop.** Run the cache-budget pass on its
own thread every minute, and track session directory sizes at write time
instead of globbing 20 GB of fragments every 5 s. Cache `close_enough?`'s
frontier per run and advance it, rather than walking every ready fragment
from `start_gop` on each request.

### 2.5 Grid

**★ P18. Content-addressed segment cache.** Key fragments by media file
fingerprint plus a hash of the decision (video and audio choices, variant
height) rather than by session:
`cache/streams/<fingerprint>/<decision hash>/gop-N.m4s`. Identity is
content, per invariant 2. A rewatch, a second household member on the same
title, the next episode after the credits prefetch, and every Grid
viewer on the same channel share one set of fragments. The stream token
still authorizes the request; `MediaController` resolves the session to
its stream directory. `Supervisor` keys runs by stream, not session, and
a run stays alive while any session on it is seen. The sweep counts
streams, not sessions.

**★ P19. Stations are always on the air.** With P18, one ffmpeg per
*station* (per decision hash actually in use) produces a rolling playlist
at the live position, not one per session. Tuning in points hls.js at a
playlist that already exists, so a channel change is a playlist swap with
no ffmpeg start and no wait. Neighbour prefetch shrinks to fetching the
last two segments of the adjacent channels. The scheduler knows the next
three days, so the station runner starts the next airing's run a minute
before the current one ends and the playlist carries a discontinuity into
it. Keep favourites and recently watched stations warm at all times; start
the rest on first tune and keep them alive for ten minutes after the last
viewer leaves. The guide preview becomes a fetch of the current segment,
not a session.

**P20. Pre-convert the schedule.** `Playback::Optimizer` already runs in
quiet hours. Feed it, in priority order: the next three days of airings on
stations whose files need a video transcode for the household's known
devices; the next unwatched episode of every show in Continue watching;
the rest of a season being watched. Then no channel ever needs a live
transcode and the "not tuned ahead" refusal disappears.

**P21. Cheaper neighbours until P19 lands.** Standby `maxBufferLength` down
to 10 s; nudge to live only when the buffer trails live by more than one
segment rather than every 8 s; standby sessions use the two-phase POST
(P3) and skip the details call. Add the idle sweeper that `IDLE_AFTER` was
written for, so an abandoned session stops counting against the budget
and its run is killed within a minute.

### 2.6 Audio

**P22. Build the audio graph before the first frame.** Create the
`AudioContext` and `createMediaElementSource` at the click that navigates
(a real gesture) and hand the context to the player through
`usePlayback`, so the element is routed through the graph before
`play()` is called. Never re-route a playing element: if the context is
not running when playback starts, leave the element unrouted for this
session and apply levelling through element volume only, as Safari
already does.

**P23. Verify fragment alignment.** With P1 in place, capture the first
fragment of an audio-transcode session and a copied-AC-3 session and
compare audio and video `tfdt`. If encoded audio trails by more than one
frame, add `aresample=async=1:first_pts=<start>` to `audio_args`. For
copied audio the only cure is P10, since a GOP-sized first segment shrinks
what the player has to bridge.

### 2.7 Encode speed

**P24. Finish the iGPU path.** Once fog passes the render node through, add
hardware decode (`-hwaccel vaapi -hwaccel_output_format vaapi`) and GPU
tone mapping (`tonemap_vaapi`) so a 4K HEVC HDR source is never decoded or
tone-mapped on the CPU. Today only the encoder runs on the GPU, with the
decode and `tonemapx` in software ahead of `hwupload`.

**P25. Low-latency x264 for the first run.** Measure `-tune zerolatency`,
or at least `-x264-params rc-lookahead=10:sync-lookahead=0`, against the
current `veryfast`. With 2 s segments (P10) the encoder's lookahead
pipeline becomes a visible share of first-frame time; with 6 s segments it
was hidden.

## 3. Implementation plan

Six pull requests, each shippable and measured on its own, then a
checkpoint that decides whether the Grid rebuild (P18, P19) is worth
building. Every PR runs `bin/ci` and `npm --prefix frontend run e2e` (the
Playwright suite catches playback bugs `bin/ci` skips), and records its
before and after numbers from PR 1 in §6.

### Decisions taken

- **P3 shrinks to "persist sidecars".** The expensive part of the
  serializer is the NAS directory listing; the rest is a dozen indexed
  queries. Splitting the session into two calls would change the API the
  Apple TV client decodes for tens of milliseconds. Persist the sidecar
  list, keep one response, and revisit only if PR 1 shows the serializer
  above 50 ms.
- **P13 is `WEB_CONCURRENCY=2` with 12 threads each.** fog routes one port
  to one web process, so a separate `/media` process isn't available. P11
  makes waits short, which matters more than the pool size.
- **P2 ships as enqueue-and-retry, not event mode.** An un-indexed copy
  answers 409 with `retry_after`, the player shows "Getting this ready" and
  retries on its own, and no thread is held. Event mode is only worth a
  week if production shows many un-indexed files; count them first
  (`MediaFile.where(keyframes: nil)` on the fog VM) and decide then.
- **P10 cuts on a 2 s target, not one GOP.** One GOP per segment turns a
  source with half-second GOPs into four authorized requests a second.
  Segments are the GOPs from one boundary to the first keyframe at or past
  the next 2 s mark; a single-GOP segment is served straight from its
  fragment, and `join` stays for the rest, now small.
- **The plan is versioned per session.** `SegmentPlan.for` is rebuilt from
  rows on every request, so changing the target on deploy would renumber
  segments under a session that is already playing. A
  `segment_target_ms` column on `playback_sessions`, set at creation and
  defaulting to 6000 for existing rows, fixes the plan for the session's
  life.
- **P11's readiness signal comes from one watcher in the transcoder.** A
  thread in `bin/transcoder` scans the live runs' frontiers every 20 ms
  (one cached frontier per run, not a glob) and sends
  `NOTIFY stream_ready`; `NodeLink` sends the same after a remote upload
  lands. No inotify dependency, and it works on macOS in development.
- **P22 drops the `autoPlay` attribute.** The click that starts playback
  creates and resumes the `AudioContext`. The player connects the element
  to the graph, then calls `play()` itself, so audio is routed before the
  first frame. A context that isn't running leaves the element unrouted
  for the session.
- **P19 is gated, not scheduled.** Pre-tuned neighbours already switch
  without a POST; the slow changes are cold channels and channels that
  need a transcode. P20 removes the second, P21 makes the first cheaper.
  If channel changes still miss 500 ms after PR 6, P18 and P19 are
  designed together as their own proposal.

### PR 1 — Measure (P1)

- The player records `performance.now()` at Play pressed, POST answered,
  manifest parsed, init loaded, first fragment buffered and first frame
  (`requestVideoFrameCallback`, falling back to `playing`), and at a seek
  issued and its first frame. Sent as `start` and `seek` events with a
  `timings` detail; `MediaController#events` allows the key.
- Server-Timing headers on `POST /playback_sessions`, `init` and
  `segment`: decision, keyframes, serializer, waited-for-transcoder.
- Playback decisions shows p50 and p95 per method for the last week; the
  stats overlay shows this session's breakdown.
- `frontend/e2e/streaming.spec.ts` asserts the §6.4 targets for direct
  play, remux, transcode and a far seek on the harness, with a margin for
  CI.
- Record baseline numbers from production in §6 before PR 2 lands.

### PR 2 — The Play request (P2, P3 as decided, P4, P5, P12, P13, idle sweeper)

- `ensure_keyframes`: container index only; otherwise enqueue
  `IndexKeyframesJob` (front of `heavy`, with its `AnalysisRun`) and
  answer 409 with `retry_after: 3`.
- Sidecar subtitles persisted at scan and on hook's webhooks in a jsonb
  column on `media_files`; `Subtitles::Tracks.sidecars` reads it.
- `MediaFile` ignores `keyframes` and `probe` by default; a
  `with_keyframes` scope for `SegmentPlan`, `Decision#codec_tag` and the
  index job. `SegmentPlan` memoized per session and variant.
- Decide first; place only for a video transcode. Encoder kind read from
  a row the transcoder writes at boot and hourly; the web tier never runs
  the probe. Device row written only when it changed.
- `init_ready?` also requires the run's first fragment.
- `bytes_sent` counted in memory and flushed with `touch`;
  `Cache-Control: private, max-age=21600, immutable` on init and segments.
- `failure` checked once a second inside `await`, not every 25 ms.
- `WEB_CONCURRENCY=2`, `RAILS_MAX_THREADS=12` in `stream.fog.yaml`; check
  the database pool and Postgres connection limit.
- An idle sweeper on the transcoder tick ends sessions unseen for
  `IDLE_AFTER`, and budget counting ignores sessions unseen for 30 s
  rather than 2 minutes.

### PR 3 — The browser's startup chain (P6, P7, P8, P9, P22)

- `PlayButton` starts the session on `pointerdown` into
  `prefetchedSessions`.
- hls.js, JASSUB and libpgs preloaded on idle after first paint;
  `preload="auto"`.
- The POST says `abr: true` only off the LAN (a Settings › Playback
  toggle per device, default off); without it `hls/index.m3u8` is the
  media playlist and the level is pinned.
- Safari native-HLS detection from a module-level probe; explicit
  `play()` with a muted fallback; no redundant resume seek for HLS;
  `captureStill` on pause and unmount only.
- Audio graph as decided above.
- The 409 from PR 2 handled as "Getting this ready" with automatic retry.

### PR 4 — Seeking (P14, P15, P16, P17)

- Seek bar previews while dragging and commits on release; keyboard and
  remote seeks trailing-throttled at 150 ms.
- `Supervisor` debounces requests per session for 100 ms; `Runner.stop`
  sends TERM then KILL from a reaper thread; the new run spawns before the
  old one is reaped.
- Restart when the running ffmpeg won't reach the target within 1 s by
  its throttle and the plan's GOP times, replacing `AHEAD = 4`.
- Frontier cached per run; the cache sweep on its own thread every minute
  with sizes tracked at write time.

### PR 5 — First GOP (P10, P11, P25)

- `segment_target_ms` column; new sessions at 2000 for copies. Converted
  video forces keyframes every 2 s; its grid follows the column.
- The readiness watcher and `NOTIFY stream_ready`; one `LISTEN`
  connection per Puma process fanning out through a condition variable;
  `Segments#await` waits on it with the 1 s safety check from PR 2.
- Measure x264 `rc-lookahead=10:sync-lookahead=0` and `-tune zerolatency`
  against `veryfast` on the production host and keep the fastest that holds quality.
- Run the Apple TV client against the harness to confirm AVPlayer with
  2 s segments.

### PR 6 — Grid (P20, P21, P23)

- The optimizer's queue prioritises the next three days of airings that
  need a video transcode for the household's known devices, then the next
  unwatched episode of each show in Continue watching.
- Standby buffer 10 s; nudge to live only when a standby channel trails
  live by more than a segment.
- With PR 1's timings, check first-fragment audio against video `tfdt` for
  an audio transcode and a copied AC-3 file; add `aresample` for encoded
  audio if it trails.

### Checkpoint

Compare §6 against the targets. If channel changes miss 500 ms, write
P18 and P19 up as their own proposal. P24 waits on fog passing the
render node through and is its own PR when it does.

**At the checkpoint (2026-09-29).** Locally a change to a pre-tuned
channel shows its first frame in 11 ms, far inside 500 ms, so P18 and P19
aren't started. That's the harness, though: decide again with a week of
production `tune` events on Playback decisions, above all for channels
that weren't tuned ahead, which P20 now pre-converts overnight.

### 3.1 How the build differed from the plan

- **P22, the late sound.** The plan dropped the `autoPlay` attribute and
  had the player call `play()` itself. That broke pausing a title while
  it loaded (a `pause()` no longer cancelled the start). Instead the app
  keeps one AudioContext, started by the first click or key press, and
  the player routes its element through the levelling graph as soon as
  the element exists, before it has data; the attribute stays.
- **P10, smaller versions.** Their keyframes had been a list of absolute
  times, which ffmpeg reads on two different clocks (§6). They now copy
  the original's keyframes (`-force_key_frames source`), and a smaller
  version's plan is the original's own.
- **P21's idle sweeper** ends only channels tuned ahead and left alone for
  30 minutes. Ending any session idle that long would break resuming a
  film paused for longer; budget counting stays at two minutes, which is
  also how long an idle run is kept.
- **P2's event mode** wasn't built: a file with no keyframe index answers
  "Getting this ready" and the player retries (Retry-After).
- **P13's cheaper metric** (`bytes_sent`) is added up in memory per Puma
  worker and written with the 15-second touch.
- **Found and fixed along the way:** the seek fight (PR 4), conversions
  started mid-film ignoring their keyframe grid, and the sweep thread
  calling a private method (both PR 5); two WebKit expectations tied to
  one Mac's display and decoder (before PR 1).

## 4. What this does not change

- The decision engine's ladder and reasons (§6.2) are untouched; every item
  is about how fast the chosen path starts, not which path is chosen.
- Invariants hold: nothing writes into a library root; segments stay on
  `cache`; ffmpeg stays argv-only; bytes still go out through Thruster; the
  keyframe scan still leaves an `AnalysisRun`, now including the on-demand
  case.
- P18 changes where fragments live, not who may fetch them: the stream
  token still signs one session, and `Viewing::Access` still decides at
  session creation.

## 5. Open questions, resolved

1. **Playlist size on the Apple TV client.** The client reads nothing
   about segment counts; its only "segments" are SponsorBlock ranges in
   the session JSON. PR 5 still checks AVPlayer on the harness.
2. **A second web process.** fog routes one port to one process, so PR 2
   runs two Puma workers instead.
3. **P19's warm set.** Deferred with P19 to the checkpoint.
4. **Event mode versus a 409.** A 409 with automatic retry in PR 2;
   event mode only if production shows many un-indexed files.

## 6. Measurements

### Local benchmark

`frontend/e2e/bench.spec.ts`, run with
`BENCH=1 BENCH_LABEL=<label> npx playwright test e2e/bench.spec.ts --project=chrome`
from `frontend/`. Six minutes of 1080p at 8 Mb/s with a keyframe every
5 s, played in Chrome on a 1080p screen; each file three times from the
top, each run seeking to 70 %, 30 % and 90 % of the film. Medians, in
milliseconds. This is an M1 Mac reading local disk, so a NAS and a
slower server CPU are not in these numbers; the shape is what matters.

| Path | Measure | Baseline | PR 2 | PR 3 | PR 4 | PR 5 | PR 6 |
|---|---|---|---|---|---|---|---|
| Remux | first frame | 469 | 331 | 356 | 453 | 406 | 461 |
| Remux | far seek | 341 | 424 | 405 | 449 | 443 | 463 |
| Audio conversion (AC-3 5.1) | first frame | 505 | 492 | 547 | 539 | 479 | 497 |
| Audio conversion (AC-3 5.1) | far seek | 479 | 512 | 449 | 507 | 598 | 624 |
| Video conversion (MPEG-2) | first frame | 1289 | 1149 | 1392 | 1514 | 811 | 827 |
| Video conversion (MPEG-2) | far seek | 4012 | 3081 | 7388 | 2852 | 1018 | 1064 |
| Video conversion (MPEG-2) | far seeks over 10 s | 4 of 9 | 2 of 9 | 4 of 9 | 0 of 9 | 0 of 9 | 0 of 9 |
| Grid | change to a pre-tuned channel | 27 | | | | | 11 |

A video conversion's far seeks are bimodal: about 3 s when nothing gets in
the way, 16–21 s when the fight below happens (in an earlier run, seven of
nine).

PR 2's changes are mostly invisible here: the folder listing it removes
is on the NAS, the keyframe scan it stops running inline only bites on a
file never indexed, and the database work it saves is a few milliseconds
on an idle laptop. The column is there to show it cost nothing.

PR 3's gains are outside what the benchmark times. It opens the watch page
directly and counts from the session request, so starting the session on
the press (P6), and not downloading hls.js after it (P7, visible only in a
cold first run), don't show; nor does the audio fix, which is about when
the sound is routed rather than how long anything takes.

PR 4 ends the fight: a resend never moves a run away from where the
session last asked to be, and every conversion seek landed in 1.7–3.5 s
(the slowest had been 21 s). What's left is encoding one six-second GOP
before the first frame at the new place, which PR 5 shortens. The whole
benchmark ran in 1.2 minutes rather than 2.6.

PR 5 halves a conversion: two-second GOPs put its first frame at 0.8 s
and its far seeks at about a second, the slowest 1.25 s. The remux rows
don't move because this file's own keyframes are five seconds apart, and
a copied segment can't be shorter than its GOP. PR 5 also found that a
conversion started anywhere but the top had never been cut on its grid
at all (below), so the earlier conversion columns measured ten-second
GOPs.

**Two bugs found on the way.**

- *Conversions restarted mid-film ignored their keyframe grid.* The
  expression `gte(t, start + n_forced*every)` assumed ffmpeg's `t` counts
  from the file's start under `-copyts`. On ffmpeg 9, and on
  jellyfin-ffmpeg 7 for some inputs, it counts from the run's start, so
  it never fired and x264 fell back to its own 250-frame GOPs, about 10 s.
  Fragments then covered ten seconds while the playlist promised six.
  Every spec started runs at zero, where the two readings agree. The grid
  now forces a keyframe whenever a frame crosses into the next slot since
  the last forced one, which cuts identically either way, and a spec now
  starts a conversion mid-film. Smaller versions (adaptive streams) had
  the same exposure through a list of absolute times; they now take the
  original's keyframes with `-force_key_frames source`, and their plan
  is the original's.
- *The cache sweep never ran after PR 4.* Its new thread called a private
  method. `sweep` is public now, with a spec calling it from outside.

**P25, x264 settings.** Timed through the real argument list on the
benchmark's MPEG-2 file, from a seek to 100 s, three runs each:

| Settings | First 2 s GOP | Twenty seconds of film |
|---|---|---|
| `-preset veryfast` (kept) | 1.60 s | 38.8 s |
| `+ rc-lookahead=10:sync-lookahead=0` | 1.97 s | 39.8 s |
| `-tune zerolatency` | 1.47 s | 38.1 s |

The differences are within noise, and zerolatency gives up B-frames for
them, so `veryfast` stays. (This file is deliberately noisy, which is why
it encodes below real time; a film encodes several times faster.)

**The Apple TV client** reads only the session JSON, which none of this
changes, and its tests pass (`make test`). Its player is AVFoundation's
AVPlayer, so the same player on macOS played the benchmark's three files
from the harness, given the capabilities an Apple TV reports: a single
media playlist rather than a master (PR 3), and 2 s converted segments.

| File | Method | First frame | Seek to 70 % |
|---|---|---|---|
| Bench Remux | remux | 635 ms | 261 ms |
| Bench Audio | remux (AC-3 plays as-is) | 603 ms | 207 ms |
| Bench Convert | video conversion | 1029 ms | 643 ms |

**P23, audio against video.** The first fragment of a run started at
100 s, for each way audio goes through the transcoder:

| Audio | Video starts | Audio starts |
|---|---|---|
| AAC copied | 100.000 s | 8 ms later |
| AC-3 copied (Safari) | 100.000 s | 26 ms later |
| AC-3 to AAC (Chrome) | 100.000 s | 9 ms later |
| AC-3 to E-AC-3 5.1 | 100.000 s | 26 ms later |

Each is under one audio frame (AAC's is 21 ms, AC-3's 32 ms), so nothing
to resample: the sound arriving late was the player re-routing it
mid-play, fixed in PR 3.

**What the baseline found.** A far seek on a video conversion takes about
twenty seconds, and the transcoder log shows why: ffmpeg restarted every
one to two seconds, alternating between the old position and the new one.
The browser abandons the segment request for where it was, but Rails
never sees the abort, so that request keeps waiting and re-signals its GOP
every two seconds (`Segments::RESIGNAL_EVERY`). Each re-signal is far from
the running ffmpeg, so the supervisor restarts it there, killing the run
for the new position; the new position's request does the same back. A
converted GOP never finishes between restarts, and the fight ends only
when the abandoned request gives up at `Segments::WAIT` (20 s). Remuxes
escape because their GOPs are ready in milliseconds. PR 4 fixes it: a
re-signal never overrides a newer request for the same session.

### Production

To be filled once PR 1 is deployed and a week of `startup` and `seek`
events has built up on the Playback decisions page.

| Metric | Target | Baseline | After PR 2 | After PR 3 | After PR 4 | After PR 5 | After PR 6 |
|---|---|---|---|---|---|---|---|
| First frame, direct | < 800 ms | | | | | | |
| First frame, remux | < 1.5 s | | | | | | |
| First frame, transcode | < 3 s | | | | | | |
| Far seek, remux | < 800 ms | | | | | | |
| Far seek, transcode | — | | | | | | |
| Channel change, pre-tuned | < 500 ms | | | | | | |
| Channel change, cold | — | | | | | | |
