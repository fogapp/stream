import { useState, type ReactNode } from "react";
import { cn } from "@/lib/cn";
import type { ImageInfo } from "@/types";

/**
 * A rendered artwork: the blurred placeholder and average colour paint at
 * once, the real image fades in over them when it lands, and the box is
 * sized by the caller so nothing shifts (PROPOSAL §6.4, no layout shift).
 */
export function ArtworkImage({
  image,
  sizes,
  alt = "",
  className,
  fallback,
  eager = false,
  contain = false,
}: {
  image: ImageInfo | null | undefined;
  /** The `sizes` attribute: how wide the box is at each breakpoint. */
  sizes: string;
  alt?: string;
  className?: string;
  /** What shows when there is no image at all (usually the title). */
  fallback?: ReactNode;
  eager?: boolean;
  /** A logo: transparent, fitted rather than cropped, no placeholder behind it. */
  contain?: boolean;
}) {
  const [loaded, setLoaded] = useState(false);
  if (!image) {
    return (
      <div className={cn("flex items-center justify-center overflow-hidden bg-surface-raised", className)}>
        {fallback}
      </div>
    );
  }
  return (
    <div
      className={cn("relative overflow-hidden", !contain && "bg-surface-raised", className)}
      style={contain ? undefined : { backgroundColor: image.color ?? undefined }}
    >
      {image.placeholder && !contain ? (
        <img src={image.placeholder} alt="" aria-hidden className="absolute inset-0 h-full w-full scale-110 object-cover blur-lg" />
      ) : null}
      <img
        src={image.src}
        srcSet={image.srcset}
        sizes={sizes}
        alt={alt}
        loading={eager ? "eager" : "lazy"}
        decoding="async"
        onLoad={() => setLoaded(true)}
        className={cn(
          "absolute inset-0 h-full w-full transition-opacity duration-300",
          contain ? "object-contain object-left" : "object-cover",
          loaded ? "opacity-100" : "opacity-0",
        )}
      />
    </div>
  );
}
