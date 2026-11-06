import type { InputHTMLAttributes, ReactNode } from "react";
import { cn } from "@/lib/cn";

interface RadioProps extends Omit<InputHTMLAttributes<HTMLInputElement>, "type" | "onChange" | "checked"> {
  checked: boolean;
  onChange: () => void;
  /** Visible text beside the button. Leave it out and give an `aria-label`. */
  label?: ReactNode;
}

const INPUT = "h-4 w-4 shrink-0 cursor-pointer accent-primary disabled:cursor-not-allowed";

/** One choice of several, labelled or bare. `className` lands on the label when there is one. */
export function Radio({ label, onChange, className, ...props }: RadioProps) {
  const input = <input type="radio" onChange={() => onChange()} className={cn(INPUT, label ? "mt-0.5" : className)} {...props} />;
  if (!label) return input;
  return (
    <label className={cn("flex items-start gap-2 text-sm text-foreground", className)}>
      {input}
      <span>{label}</span>
    </label>
  );
}

/** A choice that needs explaining: a bordered card with a title and a hint under it. */
export function RadioCard({
  label,
  hint,
  onChange,
  ...props
}: Omit<RadioProps, "label" | "className"> & { label: ReactNode; hint?: ReactNode }) {
  return (
    <label className="flex cursor-pointer items-start gap-3 rounded-[var(--radius-control)] border border-border p-3 text-sm has-[:checked]:border-primary">
      <input type="radio" onChange={() => onChange()} className={cn(INPUT, "mt-0.5")} {...props} />
      <span>
        <span className="block font-medium text-foreground">{label}</span>
        {hint ? <span className="block text-xs text-muted">{hint}</span> : null}
      </span>
    </label>
  );
}
