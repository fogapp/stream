import { useState } from "react";
import { Clapperboard, X } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { IconButton } from "@/components/ui/IconButton";
import type { TrailerInfo } from "@/types";

/** The title's trailer, full size, from Stream's own storage (PROPOSAL §7.2). */
export function TrailerButton({ trailer }: { trailer: TrailerInfo | null | undefined }) {
  const [open, setOpen] = useState(false);
  if (!trailer) return null;
  return (
    <>
      <Button variant="ghost" onClick={() => setOpen(true)}>
        <Clapperboard className="h-4 w-4" aria-hidden />
        Trailer
      </Button>
      {open ? <TrailerDialog trailer={trailer} onClose={() => setOpen(false)} /> : null}
    </>
  );
}

/** The trailer playing over the page, for a control that isn't this button (a "…" menu's). */
export function TrailerDialog({ trailer, onClose }: { trailer: TrailerInfo; onClose: () => void }) {
  return (
    <div role="dialog" aria-modal="true" aria-label={trailer.name ?? "Trailer"} className="fixed inset-0 z-50 flex items-center justify-center bg-background/95 p-4">
      <IconButton label="Close the trailer" onClick={onClose} className="absolute right-4 top-4">
        <X className="h-5 w-5" aria-hidden />
      </IconButton>
      <video
        src={trailer.url}
        controls
        autoPlay
        playsInline
        className="max-h-full w-full max-w-6xl rounded-[var(--radius-card)]"
        onEnded={onClose}
        onKeyDown={(event) => event.key === "Escape" && onClose()}
      />
    </div>
  );
}
