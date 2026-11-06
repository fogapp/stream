import logoMark from "@/assets/logo-mark.webp";
import { cn } from "@/lib/cn";

/**
 * Stream's logo, the play-triangle with water in it. The same artwork as the
 * favicon and the app icons (all cut from `src/assets/stream_logo.png`),
 * here with its black lifted to transparency so it sits on any surface.
 * Decorative: the word "Stream" beside it, or the page title, names it.
 */
export function BrandMark({ className }: { className?: string }) {
  return <img src={logoMark} alt="" aria-hidden width={256} height={256} draggable={false} className={cn("h-8 w-8 shrink-0 select-none", className)} />;
}
