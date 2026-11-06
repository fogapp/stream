import { useId, useRef, type ReactNode } from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { IconButton } from "@/components/ui/IconButton";

/**
 * A titled row that scrolls sideways (PROPOSAL §7.1): swipe on a phone,
 * arrows on a desktop, snapping to whole cards.
 */
export function Row({ title, children }: { title: string; children: ReactNode }) {
  const scroller = useRef<HTMLDivElement>(null);
  const headingId = useId();
  const page = (direction: 1 | -1) => {
    const element = scroller.current;
    if (element) element.scrollBy({ left: direction * element.clientWidth * 0.85, behavior: "smooth" });
  };
  return (
    <section className="space-y-3" aria-labelledby={headingId}>
      <div className="flex items-center justify-between px-4 sm:px-6 lg:px-8">
        <h2 id={headingId} className="text-base font-semibold text-foreground">{title}</h2>
        <div className="hidden gap-1 md:flex">
          <IconButton label={`Scroll ${title} back`} onClick={() => page(-1)}>
            <ChevronLeft className="h-4 w-4" aria-hidden />
          </IconButton>
          <IconButton label={`Scroll ${title} forward`} onClick={() => page(1)}>
            <ChevronRight className="h-4 w-4" aria-hidden />
          </IconButton>
        </div>
      </div>
      {/* Scrolling sideways clips up and down too: pt-1 is room for a
          hovered card's ring and the focus outline above it. */}
      <div
        ref={scroller}
        className="scrollbar-none flex snap-x snap-mandatory scroll-px-4 gap-3 overflow-x-auto px-4 pb-2 pt-1 sm:scroll-px-6 sm:px-6 lg:scroll-px-8 lg:px-8"
      >
        {children}
      </div>
    </section>
  );
}

/** Fixed card widths for rows, so a row of posters lines up with a grid. */
export const ROW_POSTER = "w-32 shrink-0 snap-start sm:w-36 lg:w-44";
export const ROW_WIDE = "w-64 shrink-0 snap-start sm:w-72 lg:w-80";
