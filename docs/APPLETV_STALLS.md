# Apple TV stalls — what was found, and what was built

Written after the first sessions of the tvOS app on a real Apple TV against
a production Stream. The evidence came from Glass traces, the transcoder and
Thruster logs, read-only queries of `playback_sessions`, `playback_events`
and `transcode_runs`, and timed reads from inside the transcoder container.
Code cites the steps below as `docs/APPLETV_STALLS.md › R<n>`.

## 1. What happened on the TV

Every Apple TV session over the period looked at was a Live TV tune
(`airing_id` set), most of them standby neighbours from the channel deck or
the guide preview, and most of them remuxes. So "playback stalled" meant the
Grid experience, not a movie pressed from a title page.

| What | Observed |
| --- | --- |
| First `init.mp4` of a fresh run | 3–8.6 s (p95 4.2 s) |
| `tune` events the TV reported | ~5.8 s to first frame, even with `ready: true` |
| Segments at the run's frontier | 0.5–3.7 s each, sometimes 5 s |
| Client gave up (499) | dozens of segment and init requests, nearly all channel flips |
| Runs started in the same second by one TV | up to 4 |

A kept trace of a 3 s segment request showed the Puma thread doing nothing
but waiting on the transcoder. The time was production time, not web time.

### Where the files were

Most of what was tuned lived on a share mounted over NFS from a second NAS
reached across a router hop. Timed reads from the transcoder container:

| Share | NFS read RTT | `dd` 64 MB | ffmpeg cold open + 2 s copy | 60 s of a 720p file |
| --- | --- | --- | --- | --- |
| Slow share (across a router) | 47 ms | 10.0 s (6.4 MB/s) | 1.8 s (57 ms warm) | 18.8 s |
| Fast share (same LAN) | 2.4 ms | 0.67 s (96 MB/s) | 21 ms | 22 ms |

On the slow share a cold remux cost ~2 s before the first byte, the
`-readrate_initial_burst 60` pulled 60 s of file at the whole pipe's speed,
and a 720p file could only be read at ~3× real time with the pipe to itself.
Four runs starting together — the deck tunes the active channel plus its
up/down/last neighbours — shared 6.4 MB/s: that was the 4–8 s init and the
slow first segments. Standby neighbours read to the end of their files at 2×
the whole time the active channel was trying to start.

### How AVPlayer fetches, and how the server reacted

The segment timeline of one 13-minute remux on the slow share:

1. init + first segment: 3.5 s.
2. For the next 80 s AVPlayer fetched exactly one segment per segment
   duration — it kept almost no forward buffer.
3. At +83 s it fetched 40 segments in 7 s (its buffer target grew), reached
   the run's frontier and then waited 0.5–3.7 s per segment for a minute.
4. Buffer full: no requests for 182 s. The supervisor stopped the run as
   idle after 2 minutes (`Supervisor::IDLE`).
5. The player drained, fetched 76 already-made segments in 2 s, went quiet
   for 217 s, and the run had to be started cold again for the rest.

During the thin-buffer phase every segment slower than real time was a
visible freeze. And the idle stop was tuned to the web's 60 s buffer:
AVPlayer's burst-then-silence pattern exceeded 2 minutes, so a run was
killed under a player that was still watching. The same happened to standby
deck slots, so "ready" tunes took 5.7 s because the picture came from a new
run.

### What the TV did not tell us

The tvOS player reported progress and `tune` only; the web reports
`startup`, `stall`, `recovery` and `seek`. None of the above was visible
from the Playback page — it had to be reconstructed from request logs.

### Other findings from the same triage

- `MediaController#subtitle` extracted an embedded track inside the request
  when the one-pass job hadn't yet: one `.sup` request held a Puma thread
  for over half an hour.
- `Api::V1::PlaybackSessionsController#create` ran ~36 queries, most of them
  `playabilities` lookups (an N+1 in the learned constraints) — times four
  per channel flip.

## 2. What was built

### R0 — Apple TV telemetry parity (client)

`clients/appletv/StreamTV/Playback/Telemetry.swift`: a `PlayerTelemetry`
attached by `PlayerModel`, the channel deck's active slot and the
live-stream view. It posts `startup` (press → session answered → first
frame), `stall` (seconds and AVPlayer's waiting reason, after the first
frame), `seek` (ms, buffered or not), `recovery` (error log entries and
`playbackStalled`, coalesced for 5 s like the web) and a `summary` kind on
stop with the access log's stalls, dropped frames, seconds watched, observed
bitrate and startup time; the Playback page words it. Whether a tune needed
a cold run is answered by `transcode_runs` rows near the tune, not stamped
on the event.

### R1 — Runs know their share's speed (transcoder)

`Playback::ShareSpeed` learns a root's bytes per second from each run's own
burst (measured 2 s in, or at exit for a run that finished inside it; a
burst already over counts only when its floor proves the share fast),
averaged in Solid Cache. `Playback::Pace` turns that into the run's
`-readrate` / `-readrate_initial_burst`: a share under 8× the file's bitrate
gets a burst of about 8 s of reading (at least 10 s of film); a standby
session gets 6 s then 1× anywhere. The supervisor holds a standby launch on
a slow root, a second at a time for up to 15 s, while a watched run on that
root hasn't made 3 GOPs.

### R2 — The resumed run's rate (transcoder)

Measured with a 300 s file, `-readrate 2 -readrate_initial_burst 4`,
SIGSTOP at 4 s for 20 s, then SIGCONT, counting GOPs a second:

| ffmpeg | After SIGCONT |
| --- | --- |
| 9.0.2 | 1 GOP/s, exactly the 2× it had: no catch-up |
| jellyfin-ffmpeg 7.1.4 | 22 GOPs in the first second (the 20 s stopped, at 2×), then 2× |

So jellyfin-ffmpeg refills after a pause, by an accident of its version.
The fix doesn't depend on it: a run whose video is copied (remux, audio
transcode) gets no `-readrate` at all and is capped only by the supervisor's
pause 120 s ahead, so it refills at the share's speed; `close_enough?`
reckons an unthrottled run at its measured speed throughout. Conversions and
channels tuned ahead keep the throttle.

### R3 — Idle and standby runs (transcoder + API)

The tvOS Grid never reported progress, never told Stream when a channel was
switched away from, and never touched a standby channel, so a Grid session
was "seen" only when AVPlayer fetched. Now the deck posts progress for the
channel on screen every 8 s, posts `standby` when changed away from, and
re-posts it every 45 s for each channel held; `standby` on a session already
on standby is that heartbeat. The supervisor no longer stops a standby
session's run for quiet: it is paused by the throttle once ahead, and
stopped when the session ends untouched after 30 minutes, which also covers
the web's deck.

### R4 — AVPlayer buffering on the TV (client + API)

Every AVPlayer item has a `preferredForwardBufferDuration`: 60 s for a
title or the channel on screen, 10 s for a channel tuned ahead and the
guide's preview, switched as a deck slot changes role (`Buffering`). The
live-stream view keeps AVPlayer's own choice for live HLS. The supervisor
pauses a run 180 s ahead of what its player last asked for and resumes it
under 120 s.

### R5 — Hygiene from the triage (web)

- Subtitles: a track the one-pass read hasn't reached is taken out by
  `ExtractSubtitleTrackJob` on a `subtitles` queue (one at a time, never
  held while watching). The request waits 15 s, then answers 503 +
  `Retry-After: 10`; the web loader and the tvOS picker ask again for up to
  15 minutes. A failed extraction is marked beside the track and answered
  422 at once for an hour.
- Session create: `Learned.constraints_for` makes two playability queries,
  not eleven; a spec counts them.

### Not done here

VAAPI/iGPU for the transcoder, per-client capability levels, and moving
slow-share media onto the LAN — the last would make R1 moot for most titles
and is the biggest single lever, but it is a hardware decision, not
Stream's.
