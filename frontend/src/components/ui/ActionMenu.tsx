import { useCallback, useEffect, useId, useLayoutEffect, useRef, useState, type KeyboardEvent, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { MoreHorizontal } from "lucide-react";
import { cn } from "@/lib/cn";

/**
 * A list of commands hung off a "…" button (where `Menu` holds a small form
 * instead). The panel is portalled and fixed to the viewport, so a card in
 * a sideways-scrolling row can open one without it being clipped.
 *
 * Children render only while open — anything they fetch waits for the
 * menu — and get `close` to call once a command has run.
 */
export function ActionMenu({
  label,
  children,
  className,
  icon,
}: {
  /** Accessible name for the trigger, e.g. "More for Heat". */
  label: string;
  children: (close: () => void) => ReactNode;
  className?: string;
  /** The trigger's icon, when it isn't "…" (with `className` to match the controls around it). */
  icon?: ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const trigger = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState<{ top: number; left: number } | null>(null);
  const menuId = useId();

  const close = (refocus = true) => {
    setOpen(false);
    setPosition(null);
    if (refocus) trigger.current?.focus();
  };

  // Below the button, right edges aligned; above it, or shifted left, when
  // that would run off the screen. Placed again as the page scrolls.
  const place = useCallback(() => {
    const button = trigger.current?.getBoundingClientRect();
    const rect = panel.current?.getBoundingClientRect();
    if (!button || !rect) return;
    const below = button.bottom + 4;
    const top = below + rect.height > window.innerHeight - 8 ? Math.max(8, button.top - 4 - rect.height) : below;
    const left = Math.min(Math.max(8, button.right - rect.width), window.innerWidth - 8 - rect.width);
    setPosition({ top, left });
  }, []);
  useLayoutEffect(() => {
    if (open) place();
  }, [open, place]);

  // Focus waits for the panel to be placed: a hidden element can't take it.
  const placed = position !== null;
  useEffect(() => {
    if (placed) panel.current?.querySelector<HTMLElement>('[role="menuitem"]')?.focus();
  }, [placed]);

  useEffect(() => {
    if (!open) return;
    const dismiss = () => {
      setOpen(false);
      setPosition(null);
    };
    const onPointerDown = (event: PointerEvent) => {
      const target = event.target as Node;
      if (!panel.current?.contains(target) && !trigger.current?.contains(target)) dismiss();
    };
    document.addEventListener("pointerdown", onPointerDown);
    window.addEventListener("scroll", place, true);
    window.addEventListener("resize", place);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
      window.removeEventListener("scroll", place, true);
      window.removeEventListener("resize", place);
    };
  }, [open, place]);

  const onKeyDown = (event: KeyboardEvent) => {
    const items = Array.from(panel.current?.querySelectorAll<HTMLElement>('[role="menuitem"]:not([aria-disabled="true"])') ?? []);
    const at = items.indexOf(document.activeElement as HTMLElement);
    const go = (index: number) => items[(index + items.length) % items.length]?.focus();
    if (event.key === "Escape") close();
    else if (event.key === "Tab") close(false);
    else if (event.key === "ArrowDown") go(at + 1);
    else if (event.key === "ArrowUp") go(at - 1);
    else if (event.key === "Home") go(0);
    else if (event.key === "End") go(items.length - 1);
    else return;
    if (event.key !== "Tab") event.preventDefault();
  };

  return (
    <>
      <button
        ref={trigger}
        type="button"
        aria-label={label}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        onClick={(event) => {
          // Cards are links: the button sits beside them, but be sure.
          event.preventDefault();
          event.stopPropagation();
          if (open) close();
          else setOpen(true);
        }}
        className={cn(
          "inline-flex h-8 w-8 items-center justify-center rounded-full bg-background/85 text-foreground transition",
          "hover:bg-surface-raised",
          className,
        )}
      >
        {icon ?? <MoreHorizontal className="h-4 w-4" aria-hidden />}
      </button>
      {open
        ? createPortal(
            <div
              ref={panel}
              id={menuId}
              role="menu"
              aria-label={label}
              onKeyDown={onKeyDown}
              style={position ?? { top: 0, left: 0, visibility: "hidden" }}
              className="fixed z-[70] max-h-[calc(100vh-1rem)] min-w-48 max-w-[calc(100vw-1rem)] overflow-y-auto rounded-[var(--radius-card)] border border-border bg-surface-raised p-1 text-left text-foreground shadow-lg"
            >
              {children(() => close())}
            </div>,
            // Inside whatever is full screen (a player), or it wouldn't show.
            document.fullscreenElement ?? document.body,
          )
        : null}
    </>
  );
}

/** One command in an `ActionMenu`. */
export function ActionMenuItem({
  icon,
  children,
  onSelect,
  disabled = false,
  autoFocus = false,
}: {
  icon?: ReactNode;
  children: ReactNode;
  onSelect: () => void;
  disabled?: boolean;
  /** Takes focus when it appears: the first item of a page switched to. */
  autoFocus?: boolean;
}) {
  return (
    <button
      type="button"
      role="menuitem"
      tabIndex={-1}
      autoFocus={autoFocus}
      aria-disabled={disabled || undefined}
      onClick={disabled ? undefined : onSelect}
      className={cn(
        "flex w-full items-center gap-2.5 rounded-[var(--radius-control)] px-2.5 py-1.5 text-left text-sm",
        disabled ? "text-muted" : "hover:bg-surface focus:bg-surface",
      )}
    >
      <span className="flex h-4 w-4 shrink-0 items-center justify-center text-muted">{icon}</span>
      <span className="min-w-0 flex-1 truncate">{children}</span>
    </button>
  );
}

/** A rule between groups of commands, or a small heading over one. */
export function ActionMenuSeparator({ label }: { label?: string }) {
  if (label) return <p className="px-2.5 pb-1 pt-2 text-xs font-medium uppercase tracking-wide text-muted">{label}</p>;
  return <div role="separator" className="my-1 h-px bg-border" />;
}
