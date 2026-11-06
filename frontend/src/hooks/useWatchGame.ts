import { useMutation } from "@tanstack/react-query";
import { api, apiErrorMessage } from "@/api/client";
import { toast } from "@/components/ui/Toast";
import type { BaseballSide, BaseballWatch } from "@/types";

/**
 * A game from Baseball, as the stream of the team whose broadcast to watch
 * (PROPOSAL §7.8): Stream finds the team's stream (making it the first
 * time), and what's done with it — the full-screen player, or the inset — is
 * the caller's. Why it can't be played is a toast.
 */
export function useWatchGame(onStream: (watch: BaseballWatch) => void) {
  return useMutation({
    mutationFn: ({ gameId, side }: { gameId: number; side: BaseballSide }) =>
      api.post<BaseballWatch>(`/baseball/games/${gameId}/watch`, { side }),
    onSuccess: onStream,
    onError: (error) => toast.error(apiErrorMessage(error, "This game couldn't be played")),
  });
}
