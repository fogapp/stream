import { Languages, Settings2 } from "lucide-react";
import { SPEEDS } from "@/components/player/playerKeymap";
import { Menu } from "@/components/ui/Menu";
import { Radio } from "@/components/ui/Radio";
import { Toggle } from "@/components/ui/Toggle";
import type { Track } from "@/types";

function trackLabel(track: Track): string {
  const language = track.language ? new Intl.DisplayNames(undefined, { type: "language" }).of(track.language) : null;
  const channels = track.channels === 6 ? "5.1" : track.channels === 8 ? "7.1" : track.channels === 2 ? "Stereo" : null;
  return [track.title ?? language ?? "Unknown", track.title && language ? language : null, track.codec?.toUpperCase(), channels]
    .filter(Boolean)
    .join(" · ");
}

/** The file's audio tracks, when it has a choice of them. */
export function AudioMenu({ tracks, current, onChoose }: { tracks: Track[]; current: number | null; onChoose: (index: number) => void }) {
  if (tracks.length <= 1) return null;
  return (
    <Menu label="Audio" placement="above" icon={<Languages className="h-5 w-5" aria-hidden />}>
      <div role="radiogroup" aria-label="Audio track" className="space-y-2">
        {tracks.map((track) => (
          <Radio
            key={track.index}
            name="audio-track"
            checked={track.index === current}
            onChange={() => {
              if (track.index !== current) onChoose(track.index);
            }}
            label={trackLabel(track)}
          />
        ))}
      </div>
    </Menu>
  );
}

/** Speed and sound. */
export function SettingsMenu({
  rate,
  onRate,
  levelling,
  night,
  nightDisabled,
  onAudio,
  fillWindow,
  onFillWindow,
}: {
  rate: number;
  onRate: (rate: number) => void;
  levelling: boolean;
  night: boolean;
  nightDisabled: boolean;
  onAudio: (change: Partial<{ levelling: boolean; night: boolean }>) => void;
  /** A player in a page: what Full Width means here. */
  fillWindow: boolean | null;
  onFillWindow: (fill: boolean) => void;
}) {
  return (
    <Menu label="Settings" placement="above" align="right" icon={<Settings2 className="h-5 w-5" aria-hidden />}>
      <div className="w-56 space-y-4">
        <div role="radiogroup" aria-label="Speed" className="space-y-2">
          <p className="text-xs font-medium uppercase tracking-wide text-muted">Speed</p>
          {SPEEDS.map((speed) => (
            <Radio key={speed} name="playback-speed" checked={rate === speed} onChange={() => onRate(speed)} label={speed === 1 ? "Normal" : `${speed}×`} />
          ))}
        </div>
        <Toggle label="Volume levelling" hint="Evens out loud and quiet titles." checked={levelling} onChange={(value) => onAudio({ levelling: value })} />
        <Toggle label="Night mode" hint="Quieter explosions, clearer dialogue." checked={night} disabled={nightDisabled} onChange={(value) => onAudio({ night: value })} />
        {fillWindow !== null ? <Toggle label="Full Width uses the full window" checked={fillWindow} onChange={onFillWindow} /> : null}
      </div>
    </Menu>
  );
}
