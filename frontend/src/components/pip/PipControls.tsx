import type { ReactNode } from "react";
import { ArrowLeftRight, Volume2, X } from "lucide-react";
import { IconButton } from "@/components/ui/IconButton";
import { Segmented } from "@/components/ui/Segmented";
import { MINI_BUTTON } from "@/components/player/FrameCorners";
import { PIP_AUDIO, PIP_AUDIO_OPTIONS, type PipAudio } from "@/lib/pip";

const SOUND_SEGMENTS = PIP_AUDIO.map((key) => ({ key, ...PIP_AUDIO_OPTIONS[key] }));

/**
 * What's over the inset (picture in picture): what it is, Swap and Close
 * along the top, whose sound plays along the bottom, and whatever the
 * picture itself offers between (a title's rewind, play and pause, skip
 * forward, and how far in it is, like the mini-player's). Shown on hover
 * or focus, like the mini-player's; a speaker stays in the corner while
 * the inset is heard.
 */
export function PipControls({
  title,
  subtitle,
  audio,
  heard,
  onAudio,
  onSwap,
  onClose,
  progress,
  children,
}: {
  title: string;
  subtitle?: string | null;
  audio: PipAudio;
  /** Whether this picture is heard now. */
  heard: boolean;
  onAudio: (audio: PipAudio) => void;
  onSwap: () => void;
  onClose: () => void;
  /** How far in a title is (0–1): a line along the bottom edge. */
  progress?: number;
  children?: ReactNode;
}) {
  return (
    <>
      {heard ? (
        <span className="pointer-events-none absolute left-2 top-2 flex h-6 w-6 items-center justify-center rounded-full bg-background/70 text-foreground shadow-md transition-opacity group-focus-within:opacity-0 group-hover:opacity-0">
          <Volume2 className="h-3.5 w-3.5" aria-hidden />
        </span>
      ) : null}
      <div className="pointer-events-none absolute inset-0 flex flex-col justify-between bg-gradient-to-b from-background/90 via-background/20 to-background/90 opacity-0 transition-opacity focus-within:opacity-100 group-hover:opacity-100">
        <div className="pointer-events-auto flex items-center gap-1 p-2">
          <p className="min-w-0 flex-1 truncate px-1 text-sm font-semibold text-foreground drop-shadow" title={subtitle ? `${title} · ${subtitle}` : title}>
            {title}
          </p>
          <IconButton label="Swap pictures (x)" className={MINI_BUTTON} onClick={onSwap}>
            <ArrowLeftRight className="h-4 w-4" aria-hidden />
          </IconButton>
          <IconButton label="Close picture in picture" className={MINI_BUTTON} onClick={onClose}>
            <X className="h-4 w-4" aria-hidden />
          </IconButton>
        </div>
        <div className="pointer-events-auto flex items-center justify-center gap-3">{children}</div>
        <div>
          <div className="pointer-events-auto flex justify-center pb-2">
            <Segmented label="Sound" segments={SOUND_SEGMENTS} value={audio} onChange={onAudio} />
          </div>
          {progress !== undefined ? (
            <div className="h-0.5 bg-foreground/20">
              <div className="h-full bg-primary" style={{ width: `${progress * 100}%` }} />
            </div>
          ) : null}
        </div>
      </div>
    </>
  );
}
