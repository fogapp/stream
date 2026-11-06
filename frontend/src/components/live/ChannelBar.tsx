import { ArrowLeft, ChevronDown, ChevronUp, LayoutGrid, PanelRight } from "lucide-react";
import { IconButton } from "@/components/ui/IconButton";

/**
 * Back, the guide, channel up/down and what's on now across the top of a
 * Grid channel (PROPOSAL §7.7): over the picture with the rest of its
 * controls, and on its own over the tuning card — so a channel that won't
 * play can always be changed without a keyboard.
 */
export function ChannelBar({
  onBack,
  onChannel,
  onGuide,
  onNow,
  nowOpen,
}: {
  onBack: () => void;
  onChannel: (step: 1 | -1) => void;
  onGuide: () => void;
  /** Open or close the On now panel down the side. */
  onNow: () => void;
  nowOpen: boolean;
}) {
  return (
    <div className="flex items-start gap-3 bg-gradient-to-b from-background/80 to-transparent px-4 pb-10 pt-4 sm:px-6">
      <IconButton label="Back (Esc)" size="lg" onClick={onBack}>
        <ArrowLeft className="h-5 w-5" aria-hidden />
      </IconButton>
      <IconButton label="Guide (g)" size="lg" onClick={onGuide}>
        <LayoutGrid className="h-5 w-5" aria-hidden />
      </IconButton>
      <span className="flex-1" />
      <IconButton label="Channel up (↑)" size="lg" onClick={() => onChannel(1)}>
        <ChevronUp className="h-5 w-5" aria-hidden />
      </IconButton>
      <IconButton label="Channel down (↓)" size="lg" onClick={() => onChannel(-1)}>
        <ChevronDown className="h-5 w-5" aria-hidden />
      </IconButton>
      <IconButton label="On now" size="lg" aria-pressed={nowOpen} onClick={onNow}>
        <PanelRight className="h-5 w-5" aria-hidden />
      </IconButton>
    </div>
  );
}
