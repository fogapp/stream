#!/usr/bin/env bash
# Spike C (docs/spikes.md): how fast is ffmpeg on THIS machine, for each rung
# of the decision engine (PROPOSAL §6.2)? Self-contained: generates its own
# 1080p sources. Run it where Stream will run, inside the production image:
#
#   docker run --rm --device /dev/dri stream bash spikes/ffmpeg-bench.sh     # with the iGPU
#   docker run --rm stream bash spikes/ffmpeg-bench.sh                       # software only
#
# Prints "×realtime" per rung: ≥1.0 means a live session keeps up; the
# proposal's software transcode cap (§6.3) is sized from the last rows.
set -uo pipefail
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
FF=(ffmpeg -hide_banner -nostdin -loglevel error -y)
DUR=60

echo "== host"
echo "cpu: $(uname -m), $( (grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs) || true) × $(nproc)"
[ "$(uname -m)" = x86_64 ] && echo "avx2: $(grep -qw avx2 /proc/cpuinfo && echo yes || echo 'NO — x264/x265 fall back to slow paths (kvm64 VM CPU type?)')"
echo "ffmpeg: $(ffmpeg -hide_banner -version | head -1)"
echo "render node: $(ls /dev/dri/renderD* 2>/dev/null || echo none)"

echo "== sources (${DUR}s each, not timed)"
"${FF[@]}" -f lavfi -i "testsrc2=size=1920x1080:rate=24000/1001:duration=$DUR" \
  -f lavfi -i "anoisesrc=d=$DUR:c=pink:r=48000:a=0.1" -filter_complex "[1:a]pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0[a]" \
  -map 0:v -map "[a]" -c:v libx264 -preset veryfast -crf 20 -c:a ac3 -b:a 448k "$W/h264_ac3.mkv"
"${FF[@]}" -f lavfi -i "testsrc2=size=1920x1080:rate=24000/1001:duration=$DUR" \
  -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -x265-params log-level=error:pools=none:frame-threads=2 \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc "$W/hevc10_hdr.mkv"
ls -la "$W"

# speed <label> <args...>: runs ffmpeg and prints DUR / wall seconds.
speed() {
  local label=$1; shift
  local t0 t1
  t0=$(date +%s.%N)
  if "${FF[@]}" "$@" 2>"$W/err"; then
    t1=$(date +%s.%N)
    # awk, not bc: the production image has no bc (the first server run
    # printed 0.0× for every rung).
    printf "%-44s %6.1f×realtime\n" "$label" "$(awk -v d="$DUR" -v a="$t0" -v b="$t1" 'BEGIN { print d / (b - a) }')"
  else
    printf "%-44s FAILED: %s\n" "$label" "$(head -c 160 "$W/err" | tr '\n' ' ')"
  fi
}

echo "== keyframe index (packet scan, no decode)"
t0=$(date +%s.%N); ffprobe -v error -select_streams v:0 -show_entries packet=pts_time,flags -of csv=p=0 "$W/h264_ac3.mkv" >/dev/null
echo "packet scan of ${DUR}s 1080p: $(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%d", (b - a) * 1000 }') ms"

echo "== rungs"
# +delay_moov: AC-3/E-AC-3 in fMP4 needs a parsed packet before the moov can
# be written (found by this spike; the transcoder must always set it).
FMP4=(-f mp4 -movflags frag_keyframe+empty_moov+delay_moov)
speed "remux (copy → fMP4)"                   -i "$W/h264_ac3.mkv" -c copy "${FMP4[@]}" /dev/null
speed "audio: AC-3 5.1 → AAC stereo"          -i "$W/h264_ac3.mkv" -map 0:a -c:a aac -ac 2 -b:a 192k "${FMP4[@]}" /dev/null
speed "audio: AC-3 5.1 → E-AC-3 5.1"          -i "$W/h264_ac3.mkv" -map 0:a -c:a eac3 -b:a 640k "${FMP4[@]}" /dev/null
speed "video sw: 1080p H.264 → H.264 veryfast" -i "$W/h264_ac3.mkv" -map 0:v -c:v libx264 -preset veryfast -crf 21 -f null -
speed "video sw: 1080p → 720p H.264 veryfast"  -i "$W/h264_ac3.mkv" -map 0:v -vf scale=-2:720 -c:v libx264 -preset veryfast -crf 22 -f null -
speed "video sw: HEVC 10-bit HDR → H.264 SDR (tonemapx)"  -i "$W/hevc10_hdr.mkv" -map 0:v \
  -vf "setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc,tonemapx=tonemap=bt2390:transfer=bt709:matrix=bt709:primaries=bt709:format=yuv420p" \
  -c:v libx264 -preset veryfast -crf 21 -f null -

if ls /dev/dri/renderD* >/dev/null 2>&1; then
  echo "== hardware"
  vainfo 2>/dev/null | grep -E "Driver version|VAProfileH264High|VAProfileHEVCMain10" | head -5
  speed "vaapi: 1080p H.264 → H.264"            -hwaccel vaapi -hwaccel_output_format vaapi -i "$W/h264_ac3.mkv" -map 0:v -c:v h264_vaapi -qp 23 -f null -
  speed "qsv: 1080p H.264 → H.264"              -hwaccel qsv -hwaccel_output_format qsv -i "$W/h264_ac3.mkv" -map 0:v -c:v h264_qsv -global_quality 23 -f null -
  speed "qsv: HEVC 10-bit HDR → H.264 SDR (gpu)" -hwaccel qsv -hwaccel_output_format qsv -i "$W/hevc10_hdr.mkv" -map 0:v \
    -vf "vpp_qsv=tonemap=1:format=nv12" -c:v h264_qsv -global_quality 23 -f null -
fi
