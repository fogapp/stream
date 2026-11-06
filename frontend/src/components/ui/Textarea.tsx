import { useId } from "react";
import type { TextareaHTMLAttributes } from "react";
import { cn } from "@/lib/cn";

interface TextareaProps extends TextareaHTMLAttributes<HTMLTextAreaElement> {
  label?: string;
  hint?: string;
}

export function Textarea({ label, hint, className, id, ...props }: TextareaProps) {
  // A label always finds its control, named or not.
  const generated = useId();
  const textareaId = id ?? props.name ?? generated;
  return (
    <div className="space-y-1.5">
      {label ? (
        <label htmlFor={textareaId} className="block text-sm font-medium text-foreground">
          {label}
        </label>
      ) : null}
      <textarea
        id={textareaId}
        className={cn(
          "min-h-20 w-full rounded-[var(--radius-control)] border border-border bg-input px-3 py-2",
          "text-base text-foreground placeholder:text-muted sm:text-sm",
          "disabled:opacity-50",
          className,
        )}
        {...props}
      />
      {hint ? <p className="text-xs text-muted">{hint}</p> : null}
    </div>
  );
}
