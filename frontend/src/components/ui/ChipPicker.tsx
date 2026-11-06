import { useId, useMemo, useRef, useState } from "react";
import { X } from "lucide-react";
import { cn } from "@/lib/cn";

export interface ChipOption {
  value: string;
  label: string;
  /** Beside the label in the list: a count, a year. */
  hint?: string;
}

/**
 * Choosing several from a long list (shows, networks, keywords): the chosen
 * as removable chips, and a field that narrows the rest as you type. Enter
 * takes the highlighted match — or, with `allowCustom`, what was typed.
 */
export function ChipPicker({
  label,
  hint,
  options,
  selected,
  onChange,
  placeholder = "Type to find…",
  allowCustom = false,
}: {
  label: string;
  hint?: string;
  options: ChipOption[];
  selected: string[];
  onChange: (values: string[]) => void;
  placeholder?: string;
  allowCustom?: boolean;
}) {
  const id = useId();
  const [query, setQuery] = useState("");
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const input = useRef<HTMLInputElement>(null);
  const byValue = useMemo(() => new Map(options.map((option) => [option.value, option])), [options]);
  const matches = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return options
      .filter((option) => !selected.includes(option.value) && (!needle || option.label.toLowerCase().includes(needle)))
      .slice(0, 8);
  }, [options, selected, query]);

  const add = (value: string) => {
    if (!value || selected.includes(value)) return;
    onChange([...selected, value]);
    setQuery("");
    setActive(0);
  };

  return (
    <div className="space-y-1.5">
      <label htmlFor={id} className="block text-sm font-medium text-foreground">
        {label}
      </label>
      <div
        className="flex min-h-9 flex-wrap items-center gap-1.5 rounded-[var(--radius-control)] border border-border bg-input px-2 py-1"
        onClick={() => input.current?.focus()}
      >
        {selected.map((value) => (
          <span key={value} className="flex items-center gap-1 rounded-[var(--radius-control)] bg-surface-raised px-2 py-0.5 text-sm">
            {byValue.get(value)?.label ?? value}
            <button
              type="button"
              aria-label={`Remove ${byValue.get(value)?.label ?? value}`}
              className="text-muted hover:text-foreground"
              onClick={(event) => {
                event.stopPropagation();
                onChange(selected.filter((chosen) => chosen !== value));
              }}
            >
              <X className="h-3.5 w-3.5" aria-hidden />
            </button>
          </span>
        ))}
        <div className="relative min-w-32 flex-1">
          <input
            ref={input}
            id={id}
            role="combobox"
            aria-expanded={open && matches.length > 0}
            aria-controls={`${id}-list`}
            aria-activedescendant={open && matches[active] ? `${id}-${active}` : undefined}
            aria-autocomplete="list"
            value={query}
            placeholder={selected.length === 0 ? placeholder : undefined}
            className="h-7 w-full bg-transparent text-base text-foreground placeholder:text-muted focus:outline-none sm:text-sm"
            onChange={(event) => {
              setQuery(event.target.value);
              setOpen(true);
              setActive(0);
            }}
            onFocus={() => setOpen(true)}
            onBlur={() => window.setTimeout(() => setOpen(false), 120)}
            onKeyDown={(event) => {
              if (event.key === "ArrowDown") {
                setOpen(true);
                setActive((index) => Math.min(index + 1, matches.length - 1));
              } else if (event.key === "ArrowUp") {
                setActive((index) => Math.max(index - 1, 0));
              } else if (event.key === "Enter") {
                const match = matches[active];
                if (match) add(match.value);
                else if (allowCustom && query.trim()) add(query.trim());
                else return;
              } else if (event.key === "Backspace" && query === "" && selected.length > 0) {
                onChange(selected.slice(0, -1));
              } else if (event.key === "Escape") {
                setOpen(false);
              } else return;
              event.preventDefault();
            }}
          />
          {open && matches.length > 0 ? (
            <ul
              id={`${id}-list`}
              role="listbox"
              className="absolute left-0 top-full z-30 mt-1 max-h-72 w-72 max-w-[80vw] overflow-y-auto rounded-[var(--radius-card)] border border-border bg-surface-raised p-1 shadow-lg"
            >
              {matches.map((option, index) => (
                <li
                  key={option.value}
                  id={`${id}-${index}`}
                  role="option"
                  aria-selected={index === active}
                  className={cn("flex cursor-pointer items-center gap-2 rounded-[var(--radius-control)] px-2 py-1.5 text-sm", index === active && "bg-surface")}
                  onMouseDown={(event) => {
                    event.preventDefault();
                    add(option.value);
                  }}
                  onMouseEnter={() => setActive(index)}
                >
                  <span className="min-w-0 flex-1 truncate">{option.label}</span>
                  {option.hint ? <span className="shrink-0 text-xs text-muted">{option.hint}</span> : null}
                </li>
              ))}
            </ul>
          ) : null}
        </div>
      </div>
      {hint ? <p className="text-xs text-muted">{hint}</p> : null}
    </div>
  );
}
