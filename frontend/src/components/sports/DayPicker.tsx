import { ChevronLeft, ChevronRight } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { IconButton } from "@/components/ui/IconButton";
import { dayLabel } from "@/lib/baseball";

/** A scoreboard's day, the days either side that have games, and the way back to today. */
export function DayPicker({
  day,
  onDay,
}: {
  day: { date: string; today: string; previous_date: string | null; next_date: string | null };
  /** Null is today. */
  onDay: (date: string | null) => void;
}) {
  return (
    <div className="flex items-center gap-1">
      <IconButton label="Day before" disabled={!day.previous_date} onClick={() => onDay(day.previous_date)}>
        <ChevronLeft className="h-4 w-4" aria-hidden />
      </IconButton>
      <span className="min-w-28 text-center text-sm font-medium text-foreground">{dayLabel(day.date, day.today)}</span>
      <IconButton label="Day after" disabled={!day.next_date} onClick={() => onDay(day.next_date)}>
        <ChevronRight className="h-4 w-4" aria-hidden />
      </IconButton>
      {day.date !== day.today ? (
        <Button size="sm" variant="ghost" onClick={() => onDay(null)}>
          Today
        </Button>
      ) : null}
    </div>
  );
}
