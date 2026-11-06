import { useEffect, useState } from "react";
import { X } from "lucide-react";
import { IconButton } from "@/components/ui/IconButton";
import { cn } from "@/lib/cn";

/**
 * The console's one transient-message surface.
 *
 * Exists because the UI is server-state-driven: a failed mutation refetches
 * the unchanged value and the control quietly snaps back, which reads as a
 * no-op rather than a failure. Queries have LoadingState/ErrorState; this is
 * the mutation-side counterpart, wired once through MutationCache.onError so
 * no individual button has to remember to report bad news.
 *
 * Mounted once at the root, above the routes, so the full-screen players
 * (outside the app shell) can speak too.
 */

// Errors only for now: nothing has ever had good news urgent enough for a
// toast; "info" arrived with remediations — a bulk action that returns
// in 200ms needs one line saying what it did.
export type ToastKind = "error" | "info";
export interface ToastOptions {
  /** A bold first line: what it was about ("Couldn't play Heat"). */
  title?: string;
  /**
   * Stays until it's dismissed: for news the viewer may have missed while it
   * happened — a play that stopped, with the player gone from the screen.
   */
  persistent?: boolean;
}
type ToastRecord = { id: number; kind: ToastKind; message: string } & ToastOptions;

let nextId = 0;
let listener: ((record: ToastRecord) => void) | null = null;

/** Imperative, so non-component code (the mutation cache) can speak. */
export const toast = {
  error(message: string, options: ToastOptions = {}) {
    listener?.({ id: nextId++, kind: "error", message, ...options });
  },
  info(message: string, options: ToastOptions = {}) {
    listener?.({ id: nextId++, kind: "info", message, ...options });
  },
};

const DISMISS_MS = 6_000;
const MAX_VISIBLE = 4;

export function Toasts() {
  const [toasts, setToasts] = useState<ToastRecord[]>([]);
  const dismiss = (id: number) => setToasts((current) => current.filter((t) => t.id !== id));

  useEffect(() => {
    listener = (record) => {
      // The same news again (a second try failing the same way) replaces the first.
      setToasts((current) => [
        ...current.filter((t) => !(t.message === record.message && t.title === record.title)).slice(-(MAX_VISIBLE - 1)),
        record,
      ]);
      if (!record.persistent) window.setTimeout(() => setToasts((current) => current.filter((t) => t.id !== record.id)), DISMISS_MS);
    };
    return () => {
      listener = null;
    };
  }, []);

  if (toasts.length === 0) return null;

  return (
    <div className="pointer-events-none fixed inset-x-4 top-4 z-[80] flex flex-col items-stretch gap-2 sm:inset-x-auto sm:right-4 sm:items-end">
      {toasts.map((t) => (
        <div
          key={t.id}
          role={t.kind === "error" ? "alert" : "status"}
          className={cn(
            "pointer-events-auto flex items-start gap-2 rounded-[var(--radius-card)] border bg-surface-raised px-3 py-2 text-sm shadow-lg sm:max-w-sm",
            t.kind === "error" ? "border-negative/50" : "border-border",
          )}
        >
          <div className="min-w-0 flex-1 py-1">
            {t.title ? <p className={cn("font-medium", t.kind === "error" ? "text-negative" : "text-foreground")}>{t.title}</p> : null}
            <p className={cn("break-words", t.title ? "text-muted" : t.kind === "error" ? "text-negative" : "text-foreground")}>{t.message}</p>
          </div>
          {t.persistent ? (
            <IconButton label="Dismiss" className="-mr-1 shrink-0" onClick={() => dismiss(t.id)}>
              <X className="h-4 w-4" aria-hidden />
            </IconButton>
          ) : null}
        </div>
      ))}
    </div>
  );
}
