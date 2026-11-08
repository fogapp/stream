import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "react-router-dom";
import { Shuffle } from "lucide-react";
import { apiErrorMessage } from "@/api/client";
import { usePlaybackActions } from "@/hooks/usePlayback";
import { seasonQuery } from "@/lib/queries";
import { shuffled } from "@/lib/shuffle";
import { Button } from "@/components/ui/Button";
import { toast } from "@/components/ui/Toast";
import type { NextItem, ShowDetail } from "@/types";

/**
 * Every episode here, in a random order, one after another: the first
 * plays and the rest become Play next, replacing whatever was queued.
 * Specials stay out unless they're all there is.
 */
export function ShuffleShow({ show }: { show: ShowDetail }) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { replaceQueue } = usePlaybackActions();
  const [loading, setLoading] = useState(false);
  const available = show.seasons.filter((season) => season.available_count > 0);
  const regular = available.filter((season) => season.season_number > 0);
  const seasons = regular.length > 0 ? regular : available;
  if (seasons.length === 0) return null;

  const shuffle = async () => {
    setLoading(true);
    try {
      const details = await Promise.all(
        seasons.map((season) =>
          queryClient.fetchQuery(seasonQuery(show.id, season.season_number)),
        ),
      );
      const episodes = shuffled(details.flatMap((season) => season.episodes).filter((episode) => episode.available));
      const [first, ...rest] = episodes;
      if (!first) return;
      replaceQueue(
        rest.map(
          (episode): NextItem => ({
            kind: "episode",
            id: episode.id,
            code: episode.code,
            title: episode.title,
            show_title: show.title,
            image: episode.images.still ?? episode.images.thumb ?? null,
            playlist_id: null,
          }),
        ),
      );
      navigate(`/watch/episode/${first.id}`);
    } catch (error) {
      toast.error(apiErrorMessage(error, `Couldn't shuffle ${show.title}.`));
    } finally {
      setLoading(false);
    }
  };

  return (
    <Button size="lg" variant="ghost" onClick={() => void shuffle()} disabled={loading}>
      <Shuffle className="h-4 w-4" aria-hidden />
      Shuffle
    </Button>
  );
}
