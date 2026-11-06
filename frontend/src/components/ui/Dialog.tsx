import { useEffect, useRef, type ReactNode } from "react";
import { X } from "lucide-react";
import { IconButton } from "@/components/ui/IconButton";
import { cn } from "@/lib/cn";

/**
 * A modal panel: named, closed by Escape, the backdrop or its close button,
 * Tab kept inside it, and focus handed back to where it came from.
 */
export function Dialog({
  label,
  onClose,
  children,
  className,
}: {
  label: string;
  onClose: () => void;
  children: ReactNode;
  className?: string;
}) {
  const panel = useRef<HTMLDivElement>(null);
  const close = useRef(onClose);
  close.current = onClose;

  useEffect(() => {
    const returnTo = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const focusable = () =>
      [...(panel.current?.querySelectorAll<HTMLElement>("button, a[href], input, select, textarea, [tabindex]:not([tabindex='-1'])") ?? [])].filter(
        (element) => !element.hasAttribute("disabled"),
      );
    (focusable()[1] ?? focusable()[0])?.focus();
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        event.preventDefault();
        close.current();
        return;
      }
      if (event.key !== "Tab") return;
      const items = focusable();
      const first = items[0];
      const last = items.at(-1);
      if (!first || !last) return;
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    document.addEventListener("keydown", onKey, true);
    return () => {
      document.removeEventListener("keydown", onKey, true);
      returnTo?.focus({ preventScroll: true });
    };
  }, []);

  return (
    <div className="fixed inset-0 z-[70] flex items-end justify-center bg-background/70 p-0 sm:items-center sm:p-6" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <div
        ref={panel}
        role="dialog"
        aria-modal="true"
        aria-label={label}
        className={cn("relative w-full max-w-lg rounded-t-[var(--radius-card)] border border-border bg-surface p-5 shadow-xl sm:rounded-[var(--radius-card)]", className)}
      >
        <IconButton label="Close" className="absolute right-3 top-3" onClick={onClose}>
          <X className="h-4 w-4" aria-hidden />
        </IconButton>
        {children}
      </div>
    </div>
  );
}
