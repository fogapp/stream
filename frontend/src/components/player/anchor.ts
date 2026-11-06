import { useLayoutEffect, useState } from "react";
import type { Box } from "@/components/player/miniFrame";

/**
 * Where an element sits on the page, in page coordinates: the player lives
 * above the router and is laid over a page's slot rather than inside it, so
 * moving between the page and the corner never restarts the picture. The
 * window scrolls, so a box in page coordinates only changes when the layout
 * does. (`page: false`: in the window's, for an element fixed in it.)
 */
export function useAnchorBox(anchor: HTMLElement | null, { page = true }: { page?: boolean } = {}): Box | null {
  const [box, setBox] = useState<Box | null>(null);
  useLayoutEffect(() => {
    if (!anchor) {
      setBox(null);
      return;
    }
    const measure = () => {
      const rect = anchor.getBoundingClientRect();
      const scrollX = page ? window.scrollX : 0;
      const scrollY = page ? window.scrollY : 0;
      const next = { left: rect.left + scrollX, top: rect.top + scrollY, width: rect.width, height: rect.height };
      setBox((previous) =>
        previous && previous.left === next.left && previous.top === next.top && previous.width === next.width && previous.height === next.height ? previous : next,
      );
    };
    measure();
    // The slot's own size, and anything above it that moves it down.
    const observer = new ResizeObserver(measure);
    observer.observe(anchor);
    observer.observe(document.body);
    window.addEventListener("resize", measure);
    return () => {
      observer.disconnect();
      window.removeEventListener("resize", measure);
    };
  }, [anchor, page]);
  return box;
}
