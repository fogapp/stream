# Phase 0 spikes

*2026-09-25. What the three Phase 0 spikes (PROPOSAL §11) measured before
the playback engine is built on their answers. The spike code was
throwaway and has gone, except `spikes/ffmpeg-bench.sh`, kept so Spike C
can be run again.*

**Verdict:** the design holds, with five corrections folded back into the
proposal:
1. The images ship jellyfin-ffmpeg 7, not Debian's ffmpeg.
2. Remux cuts at every keyframe and joins GOPs into segments.
3. ffmpeg is throttled with `-readrate` instead of SIGSTOP.
4. Thruster's write timeout is disabled.
5. The keyframe index reads container indexes before scanning packets.

| Spike | Question | Answer |
|---|---|---|
| A | Can Thruster serve multi-GB files with Range from an X-Sendfile answer without holding Puma? | Yes, once `HTTP_WRITE_TIMEOUT=0` is set; the default cut every response at 30 s |
| B | Does a keyframe-indexed fMP4 HLS remux play in Chrome and Safari and seek instantly? | Yes: first frame 0.3–0.7 s, a seek that restarts ffmpeg 0.2–0.4 s, no errors across run seams |
| C | How fast is ffmpeg for each rung of the decision engine? | On a 4-vCPU VM of a mobile Intel i5 with AVX2: 7× for 1080p H.264, 4.6× for HEVC HDR → SDR, in software. **Not measured here:** a CPU without AVX2, and the iGPU |

## Spike A — Thruster X-Sendfile with Range

`spikes/sendfile/config.ru`: a Rack app that answers only with an
`X-Sendfile` header, behind `thrust`, on a Puma with **one** thread. The file
is a 4 GiB sparse file.

| Check | Result |
|---|---|
| Thruster announces `X-Sendfile-Type` to the app | Yes (the app refuses without it) |
| `Range: bytes=4000000000-4000999999` | `206`, correct `Content-Range … /4294967296`, 71 ms |
| 8 concurrent full downloads + a 9th small request | The 9th got its first byte in **62 ms** while all 8 streamed (~28 MB/s each through the Docker Desktop bind mount): Puma's single thread was never held |
| Long transfers | **All 8 were cut at 30.2 s.** Thruster's `HTTP_WRITE_TIMEOUT` defaults to 30 s. With `HTTP_WRITE_TIMEOUT=0` a throttled 20 MB/s client ran until curl's own 45 s limit |

**Decision:** `HTTP_WRITE_TIMEOUT=0` in the `Dockerfile` and
`stream.fog.yaml`. Without it, every direct-play stream of a film dies 30 s in.

**Addendum (2026-09-25, Phase 1).** The spike's app was plain Rack, so it
never went through Rails' middleware. Inside Rails, `Rack::Sendfile` (Rack
3.2) deliberately ignores the `X-Sendfile-Type` request header Thruster
sends, as a guard against clients switching on `X-Accel-Redirect`. Without
`config.action_dispatch.x_sendfile_header = "X-Sendfile"` in production,
`send_file` streams every byte through Puma. It is now set in
`config/environments/production.rb`, and `MediaController` chooses its
path from that configuration, never from a request header.

## Spike B — keyframe-indexed fMP4 HLS remux

`spikes/hls_remux/`. The source is a 10-minute 720p H.264 file with AAC
stereo and AC-3 5.1 audio in MKV, which Safari can't open. Its keyframes are
deliberately irregular (3.7–6.3 s apart).

### What ffmpeg actually does (and why the first design was wrong)

1. **ffmpeg's `hls_time` rule is cumulative from wherever the run
   started.** It cuts at the first keyframe ≥ `first_pts + n × hls_time`. A
   run restarted for a seek starts counting again, so its cuts only match a
   playlist computed from zero by luck. A fixed playlist cannot rely on
   `hls_time` cuts.
2. **The segment muxer honours explicit `-segment_times`, but its fMP4
   output rebases every file to tfdt 0.** That breaks timeline continuity.
3. **Debian bookworm's ffmpeg 5.1 rebases every run to tfdt 0 even through
   the HLS muxer**, with or without `use_editlist=0` or `frag_discont`. A
   restarted run's segments can't continue the timeline.
4. **ffmpeg 7+ with `-hls_segment_options movflags=+frag_discont` writes
   absolute tfdt, and an identical init segment from every run.** Checked
   on upstream 9.0 and jellyfin-ffmpeg 7.1.4. For example, GOP 40 at
   149.337 s has tfdt `2389392` at timescale 16000.

### The design that works

- ffmpeg runs `-c copy -copyts` into fMP4 HLS with `hls_time 0.001`, so it
  **cuts at every keyframe**. Files are named by GOP index
  (`-start_number <gop>`), so every restart reproduces byte-compatible
  fragments. `-hls_flags temp_file` makes a file's existence mean it's
  complete.
- The playlist comes from the keyframe index before ffmpeg runs. Planned
  segment N is the GOPs from boundary N up to boundary N+1, on a ~6 s rule.
- A request for segment N **joins its GOP fragments** into one media
  segment; concatenated moof/mdat pairs are a valid fMP4 segment. If the live
  run won't reach those GOPs soon, ffmpeg restarts at segment N's first
  keyframe.
- **Throttling** uses ffmpeg 7's own
  `-readrate 2 -readrate_initial_burst 30`: the first 30 s arrive as fast as
  the disk allows, then ffmpeg reads at twice real time. This replaces the
  proposal's SIGSTOP plan. Without it, a local remux finished the whole
  10-minute file in about a second, so a paused or abandoned session would
  remux the entire film.

### What a real film taught (2026-10-01)

The spike's file had no B-frames, and neither did any fixture after it. A
night of Grid on a film that does found what that hid:

- **ffmpeg moves an input seek back 3/23 s** when the file has B-frames and
  its container doesn't seek by presentation time (Matroska; MP4 does). A
  seek 10 ms past a keyframe landed on the one before: every fragment of a
  restarted run was named one GOP off, and its first had no audio. The seek
  now aims past that backoff, with `-noaccurate_seek` so converted audio
  starts with the keyframe.
- **The name ffmpeg gives a fragment isn't trusted.** A run writes into a
  directory of its own; each fragment is read (`Playback::Fragment`) and
  published under the GOP whose keyframe it starts on, once
  (`Playback::Publisher`). A fragment's address then really does never
  change what it serves.
- **Chrome's MediaSource drops a buffered GOP's picture** when the GOP before
  it is appended afterwards and overruns its keyframe by a millisecond —
  Matroska's rounded timestamps do, at about half of all keyframes — and
  still reports the range whole. The player lets go of anything buffered
  past the piece a fragment joins before fetching it (`timing.ts ›
  islandsFrom`), and watches for a clock moving with no frame decoded
  (`watchdog.ts`).
- Fixtures now include a film with B-frames and uneven keyframes (the
  supervisor spec's, and the e2e seed's Long Take, whose picture says what
  second it is: `frontend/e2e/seams.spec.ts`).

### Measurements

Chrome is the Google Chrome installed on this Mac (112, from 2023), driven
through Playwright's `chrome` channel because Playwright's own Chromium
lacks H.264. WebKit is Playwright's WebKit 26.5 on macOS. The
server ran in the dev image on this Mac, reading through a bind mount. Each
cell covers three cold-cache runs; far seeks restarted ffmpeg at GOP 112
(415.7 s).

| Browser | First frame | Far seek (ffmpeg restart) | Near seek | Seek back (cached) | Across a run seam |
|---|---|---|---|---|---|
| Chrome, hls.js/MSE | 658–742 ms | 311–384 ms | 131–137 ms | 123–165 ms | plays through, no errors |
| WebKit, native HLS | 319–414 ms | 213–238 ms | 118–137 ms | 159–239 ms | plays through, no errors |
| WebKit, hls.js/MSE | 298–353 ms | 500–562 ms | 475–482 ms | 519–520 ms | plays through, no stalls |

All are inside the proposal's targets (§6.4: first frame under 1.5 s and seek
under 800 ms for remux). WebKit's hls.js path is consistently slower to seek
than its native HLS, which supports the plan to use native HLS on Safari.

### Also found

- **AC-3 and E-AC-3 in fMP4 need `movflags=+delay_moov`.** Otherwise the moov
  can't be written before the first packet is parsed. The transcoder must
  always set it.
- **The packet-scan keyframe index reads the whole file:** 3.6 s for the
  520 MB spike file through the bind mount. A 30 GB remux on the NAS would
  take minutes. **Phase 1 reads the container's own index first** (Matroska
  Cues, MP4 `stss`), which costs a few KB. The packet scan runs on the
  `heavy` queue only when no index exists, as Jellyfin does.
- Playwright's WebKit reports native HLS support and plays fMP4 HLS, so
  Safari-path tests can run headlessly on macOS. It is still not Safari: test
  on a real Safari before shipping each playback phase.

## Spike C — ffmpeg speed per rung

`spikes/ffmpeg-bench.sh` is self-contained: it generates its own 1080p
sources, then times each rung of the decision engine and prints its speed as
a multiple of real time.

**Reference run: this Mac, Docker Desktop, 4 vCPU arm64, jellyfin-ffmpeg
7.1.4.** This is **not** the target hardware, so treat it as a sanity check
only.

| Rung | ×realtime |
|---|---|
| Packet-scan keyframe index, 60 s 1080p | 60–100 ms |
| Remux (copy → fMP4) | ~970× |
| Audio: AC-3 5.1 → AAC stereo | ~72× |
| Audio: AC-3 5.1 → E-AC-3 5.1 | ~132× |
| Video, software: 1080p H.264 → H.264 veryfast | 6.5× |
| Video, software: 1080p → 720p H.264 veryfast | 9.5× |
| Video, software: HEVC 10-bit HDR → H.264 SDR (`tonemapx`) | 4.1× |

The remux and audio rungs are nearly free, as the proposal assumed.
jellyfin-ffmpeg's SIMD `tonemapx` filter does the software HDR → SDR path;
the zscale chain was fragile and is dropped.

**Server run, 2026-09-25.** The run happened on a VM with its CPU type set
to `host` (4 vCPU of a mobile Intel i5, AVX2 available), using the
production image (jellyfin-ffmpeg 7.1.4). That VM has no render node, so
both passes were software.

| Rung | ×realtime |
|---|---|
| Packet-scan keyframe index, 60 s 1080p | 29 ms |
| Remux (copy → fMP4) | ~1,244× |
| Audio: AC-3 5.1 → AAC stereo | ~65× |
| Audio: AC-3 5.1 → E-AC-3 5.1 | ~187× |
| Video, software: 1080p H.264 → H.264 veryfast | 7.0× |
| Video, software: 1080p → 720p H.264 veryfast | 11.9× |
| Video, software: HEVC 10-bit HDR → H.264 SDR (`tonemapx`) | 4.6× |

What this settles: with AVX2, even the hardest software path (HEVC 10-bit
HDR tone-mapped to H.264) runs 4.6× faster than playback. Each run is
throttled to 2× real time after its first 30 s (`-readrate 2`), so two
conversions at once fit on these 4 vCPU.

What it doesn't settle:

- **A CPU without AVX2.** A VM left on its hypervisor's default virtual CPU
  (`kvm64`, "Common KVM processor") converts several times slower than
  these numbers; setting its CPU type to `host` is what makes this table
  apply.
- **The iGPU.** Hardware conversion needs the iGPU passed through to the VM
  that runs the transcoder, and fog then has to pass `/dev/dri` into the
  container (PROPOSAL §9.3).

To repeat a run, run `spikes/ffmpeg-bench.sh` inside the production image,
once with the iGPU passed through and once without.

It prints whether the CPU has AVX2. A `kvm64` CPU type has no AVX2, and
x264/x265 slow down several times without it. It also prints QSV and VAAPI
speeds when a render node is visible. Those numbers set the default for
simultaneous video transcodes (§6.3) and confirm the iGPU tone-mapping
path.

## Changes folded back

| Where | Change |
|---|---|
| `Dockerfile`, `Dockerfile.dev`, CI | jellyfin-ffmpeg 7 from repo.jellyfin.org replaces Debian's ffmpeg 5.1 and fpcalc (it has a chromaprint muxer) |
| `Dockerfile`, `stream.fog.yaml` | `HTTP_WRITE_TIMEOUT=0` |
| PROPOSAL §5.3 | Keyframe index: container index first, packet scan as fallback |
| PROPOSAL §6.3 | GOP-fragment remux, `-readrate` throttle, `+delay_moov`, `tonemapx` |
| `bin/media-fixtures`, `spec/fixtures/media` | The corpus; ffmpeg can't encode PGS, VobSub or Dolby Vision from scratch, so those get real samples in Phase 2 |
