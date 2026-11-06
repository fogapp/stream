import { cn } from "@/lib/cn";

const VARIANTS = {
  /** A bar of its own: an encode's progress, a budget. */
  track: { bar: "h-1.5 overflow-hidden rounded-full bg-surface-raised", fill: "transition-[width]" },
  /** The thin bar along a card's or a picture's bottom edge: how much was watched. */
  overlay: { bar: "h-1 bg-foreground/25", fill: "" },
} as const;

/** How far along something is, 0 to 1. */
export function ProgressBar({
  value,
  label = "Watched so far",
  variant = "track",
  className,
}: {
  value: number;
  label?: string;
  variant?: keyof typeof VARIANTS;
  className?: string;
}) {
  const percent = Math.round(Math.min(1, Math.max(0, value)) * 100);
  const look = VARIANTS[variant];
  return (
    <div
      className={cn("w-full", look.bar, className)}
      role="progressbar"
      aria-valuenow={percent}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-label={label}
    >
      <div className={cn("h-full bg-primary", look.fill)} style={{ width: `${percent}%` }} />
    </div>
  );
}
