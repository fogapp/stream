import { useEffect, useRef } from "react";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/Button";

/**
 * The end of a paged list: the next page loads by itself as the list
 * scrolls within a screen of its end. A button stays for a keyboard, a
 * browser without IntersectionObserver, and a page that failed — which
 * never retries by itself, so a server that's down isn't asked in a loop.
 */
export function LoadMore({
  hasMore,
  loading,
  failed = false,
  onLoad,
  label = "Show more",
}: {
  hasMore: boolean;
  loading: boolean;
  failed?: boolean;
  onLoad: () => void;
  /** The button's words, e.g. "Earlier" for a timeline. */
  label?: string;
}) {
  const sentinel = useRef<HTMLDivElement>(null);
  const load = useRef(onLoad);
  load.current = onLoad;

  // A new observer after each page: one already in view reports at once,
  // so a page too short to fill the screen still leads to the next.
  useEffect(() => {
    const element = sentinel.current;
    if (!element || !hasMore || loading || failed || typeof IntersectionObserver === "undefined") return;
    const observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) load.current();
    }, { rootMargin: "0px 0px 100% 0px" });
    observer.observe(element);
    return () => observer.disconnect();
  }, [hasMore, loading, failed]);

  if (!hasMore) return null;
  return (
    <div ref={sentinel} className="flex justify-center py-4">
      {loading ? (
        <span role="status" className="flex items-center gap-2 text-sm text-muted">
          <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
          Loading more…
        </span>
      ) : (
        <Button variant={failed ? "secondary" : "ghost"} onClick={onLoad}>
          {failed ? "Couldn't load more. Try again" : label}
        </Button>
      )}
    </div>
  );
}
