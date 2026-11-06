import { PictureInPicture2 } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { usePlayback } from "@/hooks/usePlayback";
import { sameSource, type PipSource } from "@/lib/pip";

/**
 * Beside Play while something is playing: this in the inset over it
 * (picture in picture) instead of in its place. Nothing when nothing plays,
 * or when this is what plays.
 */
export function PipButton({ source, size = "lg" }: { source: PipSource; size?: "md" | "lg" }) {
  const { current, pip, openPip } = usePlayback();
  if (!current) return null;
  const playing = source.kind === "title" && current.kind === source.playable && current.id === source.id;
  if (playing || sameSource(source, pip)) return null;
  return (
    <Button size={size} variant="secondary" onClick={() => openPip(source)}>
      <PictureInPicture2 className="h-4 w-4" aria-hidden />
      Picture in picture
    </Button>
  );
}
