import { useMutation, useQueryClient, type QueryClient, type QueryKey } from "@tanstack/react-query";
import { toast } from "@/components/ui/Toast";

/** One thing a "…" menu does: the request, what to say when it's done, and what it changed. */
export interface MenuAction {
  work: () => Promise<unknown>;
  done: string;
  /** The keys the change moves, or a function for a change that moves more than keys (lib/watched). */
  refresh?: ReadonlyArray<QueryKey> | ((queryClient: QueryClient) => void);
}

/**
 * Runs a menu's action as a mutation. The menu has usually closed (and
 * unmounted) by the time the request answers, so the confirmation toast and
 * the invalidations live on the mutation, not the caller; a failure gets the
 * shared MutationCache toast like any other mutation.
 */
export function useMenuAction() {
  const queryClient = useQueryClient();
  const { mutate } = useMutation({
    mutationFn: (action: MenuAction) => action.work(),
    onSuccess: (_data, { done, refresh }) => {
      if (typeof refresh === "function") refresh(queryClient);
      else for (const queryKey of refresh ?? []) void queryClient.invalidateQueries({ queryKey });
      toast.info(done);
    },
  });
  return mutate;
}
