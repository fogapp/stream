import { cn } from "@/lib/cn";

export interface ToggleChipOption<V extends string> {
  value: V;
  label: string;
}

/**
 * A filter over a short closed vocabulary where any number may be on — the
 * methods a play went by, the states a version is in. Each chip is a
 * toggle button; none on means no filter.
 */
export function ToggleChips<V extends string>({
  label,
  options,
  selected,
  onChange,
}: {
  label: string;
  options: readonly ToggleChipOption<V>[];
  selected: readonly string[];
  onChange: (values: V[]) => void;
}) {
  return (
    <div role="group" aria-label={label} className="flex flex-wrap items-center gap-1.5">
      <span className="mr-1 text-xs text-muted" aria-hidden>
        {label}
      </span>
      {options.map((option) => {
        const on = selected.includes(option.value);
        return (
          <button
            key={option.value}
            type="button"
            aria-pressed={on}
            onClick={() =>
              onChange(
                on
                  ? options.filter((each) => each.value !== option.value && selected.includes(each.value)).map((each) => each.value)
                  : options.filter((each) => each.value === option.value || selected.includes(each.value)).map((each) => each.value),
              )
            }
            className={cn(
              "h-8 rounded-full border px-3 text-xs font-medium transition-colors",
              on
                ? "border-primary/40 bg-primary/10 text-primary"
                : "border-border bg-surface text-muted hover:border-primary/30 hover:text-foreground",
            )}
          >
            {option.label}
          </button>
        );
      })}
    </div>
  );
}
