import { useEffect, useId, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { cn } from "@/lib/cn";

/**
 * A popover hung off a button, for the controls a page needs to keep but not
 * to show: settings that are set once and then left alone. The panel holds
 * arbitrary children rather than a list of menu items, because what gets
 * tucked away here is usually a small form (a show's auto-skip preferences),
 * not a set of commands.
 *
 * Dismissal is a pointerdown outside, or Escape.
 */
export function Menu({
  label,
  icon,
  children,
  align = "right",
  placement = "below",
  className,
}: {
  /** Accessible name for the trigger — the panel's heading too. */
  label: string;
  icon: ReactNode;
  children: ReactNode;
  align?: "left" | "right";
  /** Above for a control bar along the bottom of the screen (the player). */
  placement?: "below" | "above";
  className?: string;
}) {
  const [open, setOpen] = useState(false);
  const container = useRef<HTMLDivElement>(null);
  const panelId = useId();

  useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: PointerEvent) => {
      if (!container.current?.contains(event.target as Node)) setOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
    };
    document.addEventListener("pointerdown", onPointerDown);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [open]);

  // A panel that would run off the screen flips to the other side.
  const panel = useRef<HTMLDivElement>(null);
  const [side, setSide] = useState(align);
  useLayoutEffect(() => {
    if (!open) {
      setSide(align);
      return;
    }
    const rect = panel.current?.getBoundingClientRect();
    if (!rect) return;
    if (side === "left" && rect.right > window.innerWidth - 8) setSide("right");
    else if (side === "right" && rect.left < 8) setSide("left");
  }, [open, align, side]);

  return (
    <div ref={container} className={cn("relative", className)}>
      <button
        type="button"
        aria-expanded={open}
        aria-haspopup="true"
        aria-controls={open ? panelId : undefined}
        onClick={() => setOpen((value) => !value)}
        className={cn(
          "inline-flex h-8 items-center justify-center gap-1.5 rounded-[var(--radius-control)]",
          "border border-border bg-surface-raised px-3 text-sm font-medium transition-colors",
          open ? "text-foreground" : "text-muted hover:text-foreground",
        )}
      >
        {icon}
        <span className="sr-only">{label}</span>
      </button>

      {open ? (
        <div
          id={panelId}
          ref={panel}
          className={cn(
            "absolute z-20 w-64 max-w-[calc(100vw-2rem)] rounded-[var(--radius-card)] border border-border",
            "bg-surface-raised p-3 text-left shadow-lg",
            side === "right" ? "right-0" : "left-0",
            placement === "below" ? "top-full mt-1" : "bottom-full mb-2",
          )}
        >
          <p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted">{label}</p>
          {children}
        </div>
      ) : null}
    </div>
  );
}
