import { useEffect, useState } from "react";
import { PLAYBACK_METHOD_LABELS } from "@/lib/playback";
import { startupLabel, type Seek, type Startup } from "@/components/player/timing";
import { audioGraphInfo, soundLabel, type AudioGraphInfo, type SoundPath } from "@/components/player/audio";
import type { PlaybackSessionInfo } from "@/types";

interface Sample {
  width: number;
  height: number;
  bufferAhead: number;
  dropped: number;
  frames: number;
  graph: AudioGraphInfo | null;
}

function sample(video: HTMLVideoElement): Sample {
  const ranges = video.buffered;
  let ahead = 0;
  for (let i = 0; i < ranges.length; i += 1) {
    if (ranges.start(i) <= video.currentTime && ranges.end(i) >= video.currentTime) ahead = ranges.end(i) - video.currentTime;
  }
  const quality = video.getVideoPlaybackQuality?.();
  return {
    width: video.videoWidth,
    height: video.videoHeight,
    bufferAhead: ahead,
    dropped: quality?.droppedVideoFrames ?? 0,
    frames: quality?.totalVideoFrames ?? 0,
    graph: audioGraphInfo(video),
  };
}

/**
 * Stats for nerds (PROPOSAL §7.3): what the engine decided and how playback
 * is holding up, refreshed every second. Toggled with S.
 */
export function StatsOverlay({
  video,
  session,
  quality,
  startup = null,
  lastSeek = null,
  sound = null,
}: {
  video: HTMLVideoElement | null;
  session: PlaybackSessionInfo;
  quality?: string | null;
  startup?: Startup | null;
  lastSeek?: Seek | null;
  sound?: SoundPath | null;
}) {
  const [stats, setStats] = useState<Sample | null>(null);
  useEffect(() => {
    if (!video) return;
    const tick = () => setStats(sample(video));
    tick();
    const timer = window.setInterval(tick, 1000);
    return () => window.clearInterval(timer);
  }, [video]);

  const { video: plannedVideo, audio } = session.decision;
  const rows: [string, string][] = [
    ["Playback", `${PLAYBACK_METHOD_LABELS[session.method]} (${session.source.kind === "hls" ? "HLS" : "original file"})`],
    ["Why", session.decision.summary],
    ...(quality ? ([["Quality", quality === "Original" ? "Original (adaptive: smaller versions on demand)" : `${quality}, dropped for the network`]] as [string, string][]) : []),
    [
      "Video",
      plannedVideo
        ? plannedVideo.copy
          ? `${plannedVideo.codec} as-is`
          : `→ ${plannedVideo.codec} ${plannedVideo.height ?? ""}p${plannedVideo.tonemap ? ", tone-mapped" : ""}`
        : "none",
    ],
    ["Audio", audio ? (audio.copy ? `${audio.codec} as-is` : `→ ${audio.codec} ${audio.channels ?? ""}ch`) : "none"],
    ...(audio && sound && stats ? ([["Sound", soundLabel(sound, stats.graph, session.loudness)]] as [string, string][]) : []),
    ["Rendering", stats ? `${stats.width}×${stats.height}` : "…"],
    ["Buffer ahead", stats ? `${stats.bufferAhead.toFixed(1)} s` : "…"],
    ["Dropped frames", stats ? `${stats.dropped} of ${stats.frames}` : "…"],
    ["Started in", startup ? startupLabel(startup) : "…"],
    ...(lastSeek ? ([["Last seek", `${lastSeek.ms} ms${lastSeek.ready ? " (already buffered)" : ""}`]] as [string, string][]) : []),
    ["Session", session.id],
  ];

  return (
    <div className="pointer-events-auto absolute left-4 top-20 max-w-md rounded-[var(--radius-card)] bg-background/85 p-3 font-mono text-xs text-foreground sm:left-6">
      <table>
        <tbody>
          {rows.map(([label, value]) => (
            <tr key={label}>
              <th scope="row" className="pr-3 text-left align-top font-normal text-muted">
                {label}
              </th>
              <td className="break-all">{value}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
