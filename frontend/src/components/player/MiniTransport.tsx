import { Pause, Play, RotateCcw, RotateCw } from "lucide-react";
import { MINI_BUTTON } from "@/components/player/FrameCorners";
import { IconButton } from "@/components/ui/IconButton";

/** Back, play and on, for a picture with no room for the full controls: the corner and the inset. */
export function MiniTransport({ playing, onToggle, onStep }: { playing: boolean; onToggle: () => void; onStep: (seconds: number) => void }) {
  return (
    <>
      <IconButton label="Rewind 10 seconds" className={MINI_BUTTON} onClick={() => onStep(-10)}>
        <RotateCcw className="h-4 w-4" aria-hidden />
      </IconButton>
      <IconButton label={playing ? "Pause" : "Play"} size="lg" className={MINI_BUTTON} onClick={onToggle}>
        {playing ? <Pause className="h-5 w-5 fill-current" aria-hidden /> : <Play className="h-5 w-5 fill-current" aria-hidden />}
      </IconButton>
      <IconButton label="Skip forward 10 seconds" className={MINI_BUTTON} onClick={() => onStep(10)}>
        <RotateCw className="h-4 w-4" aria-hidden />
      </IconButton>
    </>
  );
}
