import { useEffect, useState, type ReactNode } from "react";
import { Volume2, VolumeX } from "lucide-react";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { IconButton } from "@/components/ui/IconButton";
import type { Images } from "@/types";

/** How long the backdrop shows before a trailer takes over behind it. */
const TRAILER_DELAY_MS = 2500;

/**
 * The top of a title page: the backdrop fading into the page, the logo (or
 * the title) and whatever the page puts under it.
 */
export function Hero({ images, title, children, trailerUrl }: { images: Images; title: string; children: ReactNode; trailerUrl?: string | null }) {
  const backdrop = images.backdrop ?? images.thumb;
  // A trailer behind the hero (PROPOSAL §7.1): muted, after a moment, and
  // never for someone who asked for less motion.
  const [showTrailer, setShowTrailer] = useState(false);
  const [muted, setMuted] = useState(true);
  useEffect(() => {
    setShowTrailer(false);
    if (!trailerUrl || window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return;
    const timer = window.setTimeout(() => setShowTrailer(true), TRAILER_DELAY_MS);
    return () => window.clearTimeout(timer);
  }, [trailerUrl]);
  // z-10: above what follows, so its menus open over the rows below.
  return (
    <section className="relative isolate z-10">
      <div className="absolute inset-0 -z-10">
        {backdrop ? (
          <ArtworkImage image={backdrop} sizes="100vw" className="h-full w-full" eager />
        ) : (
          <div className="h-full w-full bg-surface" />
        )}
        {showTrailer && trailerUrl ? (
          <video
            src={trailerUrl}
            autoPlay
            muted={muted}
            playsInline
            aria-hidden
            className="absolute inset-0 h-full w-full object-cover"
            onEnded={() => setShowTrailer(false)}
            onError={() => setShowTrailer(false)}
          />
        ) : null}
        <div className="absolute inset-0 bg-gradient-to-t from-background via-background/70 to-background/10" />
        <div className="absolute inset-0 bg-gradient-to-r from-background/90 via-background/40 to-transparent" />
      </div>
      <div className="flex min-h-[26rem] flex-col justify-end gap-4 px-4 pb-8 pt-24 sm:px-6 lg:min-h-[32rem] lg:px-8">
        {images.logo ? (
          <ArtworkImage
            image={images.logo}
            alt={title}
            sizes="(min-width: 1024px) 24rem, 60vw"
            className="h-20 w-full max-w-sm sm:h-28"
            contain
            eager
          />
        ) : (
          <h1 className="max-w-3xl text-3xl font-bold tracking-tight text-foreground sm:text-5xl">{title}</h1>
        )}
        {children}
      </div>
      {showTrailer && trailerUrl ? (
        <IconButton label={muted ? "Unmute the trailer" : "Mute the trailer"} onClick={() => setMuted((value) => !value)} className="absolute bottom-8 right-4 sm:right-6 lg:right-8">
          {muted ? <VolumeX className="h-4 w-4" aria-hidden /> : <Volume2 className="h-4 w-4" aria-hidden />}
        </IconButton>
      ) : null}
    </section>
  );
}
