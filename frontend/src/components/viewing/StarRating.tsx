import { useState } from "react";
import { useMutation } from "@tanstack/react-query";
import { Star, StarHalf } from "lucide-react";
import { api } from "@/api/client";
import { IconButton } from "@/components/ui/IconButton";
import { cn } from "@/lib/cn";
import { plural } from "@/lib/format";

/**
 * This profile's stars (PROPOSAL §7.4), kept out of 10 as Plex keeps them:
 * a star is 2, so Plex's half stars show. Pressing the current star clears.
 */
export function StarRating({
  kind,
  id,
  value,
  onChange,
  small = false,
}: {
  kind: "movie" | "show" | "episode";
  id: string;
  value: number | null;
  onChange: () => void;
  small?: boolean;
}) {
  const [shown, setShown] = useState(value);
  const [hover, setHover] = useState<number | null>(null);
  const rate = useMutation({
    mutationFn: (next: number | null) => api.put("/rating", { rateable_type: kind, rateable_id: id, value: next ?? "" }),
    onSuccess: onChange,
  });
  const current = hover ?? shown ?? 0;

  return (
    <div className="flex items-center" role="group" aria-label="Your rating" onMouseLeave={() => setHover(null)}>
      {[1, 2, 3, 4, 5].map((stars) => {
        const full = current >= stars * 2;
        const half = !full && current >= stars * 2 - 1;
        return (
          <IconButton
            key={stars}
            label={shown === stars * 2 ? `Clear your rating` : `Rate ${plural(stars, "star")}`}
            aria-pressed={shown !== null && shown >= stars * 2 - 1}
            onMouseEnter={() => setHover(stars * 2)}
            onClick={() => {
              const next = shown === stars * 2 ? null : stars * 2;
              setShown(next);
              rate.mutate(next);
            }}
            className="p-0.5"
          >
            {half ? (
              <StarHalf className={cn(small ? "h-3.5 w-3.5" : "h-5 w-5", "fill-current text-primary")} aria-hidden />
            ) : (
              <Star className={cn(small ? "h-3.5 w-3.5" : "h-5 w-5", full ? "fill-current text-primary" : "text-muted")} aria-hidden />
            )}
          </IconButton>
        );
      })}
    </div>
  );
}
