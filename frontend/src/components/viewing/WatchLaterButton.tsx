import { Clock, ClockCheck } from "lucide-react";
import { useWatchLater, type Saveable } from "@/hooks/useWatchLater";
import { Button } from "@/components/ui/Button";
import { IconButton } from "@/components/ui/IconButton";

/** Save for later, or take it back out. A button on pages, an icon on cards. */
export function WatchLaterButton({ item, compact = false, className }: { item: Saveable; compact?: boolean; className?: string }) {
  const { isSaved, toggle } = useWatchLater();
  const saved = isSaved(item);
  const Icon = saved ? ClockCheck : Clock;
  if (compact) {
    return (
      <IconButton label={saved ? "Remove from Watch later" : "Save to Watch later"} aria-pressed={saved} onClick={() => toggle(item)} className={className}>
        <Icon className="h-4 w-4" aria-hidden />
      </IconButton>
    );
  }
  return (
    <Button variant="ghost" aria-pressed={saved} onClick={() => toggle(item)} className={className}>
      <Icon className="h-4 w-4" aria-hidden />
      {saved ? "Saved for later" : "Watch later"}
    </Button>
  );
}
