import type { KeyboardEvent, MouseEvent, ReactNode } from "react";
import { Captions, Maximize, Minimize, Pause, Play, Radio as RadioIcon, Volume2, VolumeX } from "lucide-react";
import { IconButton } from "@/components/ui/IconButton";
import { Menu } from "@/components/ui/Menu";
import { Radio } from "@/components/ui/Radio";
import { formatClock } from "@/lib/format";
import type { SubtitleTrack } from "@/types";

/** The controls every player's bar has: the same buttons, so they stay the same buttons. */

export function PlayPauseButton({ playing, onToggle }: { playing: boolean; onToggle: () => void }) {
  return (
    <IconButton label={playing ? "Pause (k)" : "Play (k)"} size="lg" onClick={onToggle}>
      {playing ? <Pause className="h-6 w-6 fill-current" aria-hidden /> : <Play className="h-6 w-6 fill-current" aria-hidden />}
    </IconButton>
  );
}

export function FullscreenButton({ fullscreen, onToggle }: { fullscreen: boolean; onToggle: () => void }) {
  return (
    <IconButton label={fullscreen ? "Exit full screen (f)" : "Full screen (f)"} size="lg" onClick={onToggle}>
      {fullscreen ? <Minimize className="h-5 w-5" aria-hidden /> : <Maximize className="h-5 w-5" aria-hidden />}
    </IconButton>
  );
}

/** The mute button and the slider beside it. */
export function VolumeControl({
  quiet,
  volume,
  onToggleMute,
  onVolume,
}: {
  quiet: boolean;
  volume: number;
  onToggleMute: () => void;
  onVolume: (value: number) => void;
}) {
  return (
    <>
      <IconButton label={quiet ? "Unmute (m)" : "Mute (m)"} size="lg" onClick={onToggleMute}>
        {quiet || volume === 0 ? <VolumeX className="h-5 w-5" aria-hidden /> : <Volume2 className="h-5 w-5" aria-hidden />}
      </IconButton>
      <input
        type="range"
        aria-label="Volume"
        min={0}
        max={1}
        step={0.05}
        value={quiet ? 0 : volume}
        onChange={(event) => onVolume(Number(event.target.value))}
        className="hidden w-24 accent-primary sm:block"
      />
    </>
  );
}

/** At live, it says so; behind, it offers to catch up and says how far. */
export function LiveBadge({ atLive, behind, onJump, testId }: { atLive: boolean; behind: number; onJump: () => void; testId?: string }) {
  if (atLive) {
    return (
      <span
        data-testid={testId}
        className="flex shrink-0 items-center gap-1.5 rounded-[var(--radius-control)] bg-negative px-2 py-0.5 text-xs font-semibold uppercase tracking-wide text-negative-foreground"
      >
        <RadioIcon className="h-3.5 w-3.5" aria-hidden />
        Live
      </span>
    );
  }
  return (
    <button
      type="button"
      onClick={onJump}
      className="flex shrink-0 items-center gap-1.5 rounded-[var(--radius-control)] border border-border bg-surface-raised px-2 py-1 text-xs font-medium hover:bg-border/40"
    >
      <RadioIcon className="h-3.5 w-3.5" aria-hidden />
      Jump to live · −{formatClock(behind)}
    </button>
  );
}

/** How far an arrow key moves a bar with focus. */
const SCRUB_STEP_SECONDS = 10;

/**
 * A live bar: click to go there, or left and right with it focused. Those
 * stop here, so a page's own arrow shortcut doesn't move it a second time;
 * up and down go on to the page, where they change the channel.
 */
export function ScrubBar({
  label,
  max,
  now,
  text,
  onFraction,
  onStep,
  children,
}: {
  label: string;
  max: number;
  now: number;
  text: string;
  /** Pressed this far along, 0 to 1. */
  onFraction: (fraction: number) => void;
  /** An arrow key: this many seconds, back or on. */
  onStep: (seconds: number) => void;
  children: ReactNode;
}) {
  const press = (event: MouseEvent<HTMLDivElement>) => {
    const box = event.currentTarget.getBoundingClientRect();
    onFraction((event.clientX - box.left) / box.width);
  };
  const key = (event: KeyboardEvent<HTMLDivElement>) => {
    const step = event.key === "ArrowLeft" ? -SCRUB_STEP_SECONDS : event.key === "ArrowRight" ? SCRUB_STEP_SECONDS : 0;
    if (step === 0 || event.metaKey || event.ctrlKey || event.altKey) return;
    event.preventDefault();
    event.stopPropagation();
    onStep(step);
  };
  return (
    <div
      className="relative h-1.5 cursor-pointer rounded-full bg-foreground/20"
      role="slider"
      tabIndex={0}
      aria-label={label}
      aria-valuemin={0}
      aria-valuemax={Math.round(max)}
      aria-valuenow={Math.round(now)}
      aria-valuetext={text}
      onClick={press}
      onKeyDown={key}
    >
      {children}
    </div>
  );
}

/** The subtitle tracks, and Off. A track's own radio says what picking it does. */
export function SubtitleMenu({
  name,
  tracks,
  offChecked,
  checked,
  label,
  onOff,
  onPick,
}: {
  name: string;
  tracks: SubtitleTrack[];
  offChecked: boolean;
  checked: (track: SubtitleTrack) => boolean;
  label: (track: SubtitleTrack) => string;
  onOff: () => void;
  onPick: (track: SubtitleTrack) => void;
}) {
  if (tracks.length === 0) return null;
  return (
    <Menu label="Subtitles" placement="above" icon={<Captions className="h-5 w-5" aria-hidden />}>
      <div role="radiogroup" aria-label="Subtitles" className="max-h-72 space-y-2 overflow-y-auto">
        <Radio name={name} checked={offChecked} onChange={onOff} label="Off" />
        {tracks.map((track) => (
          <Radio key={track.id} name={name} checked={checked(track)} onChange={() => onPick(track)} label={label(track)} />
        ))}
      </div>
    </Menu>
  );
}
