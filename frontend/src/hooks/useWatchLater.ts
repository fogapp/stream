import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { toast } from "@/components/ui/Toast";

export type Saveable = { kind: "movie" | "episode" | "video"; id: string; title: string | null };

/** Watch later (PROPOSAL §5.4): what's saved, and one press to save or unsave. */
export function useWatchLater() {
  const queryClient = useQueryClient();
  const saved = useQuery({
    queryKey: keys.watchLater.ids(),
    queryFn: ({ signal }) => api.get<{ id: string; items: string[] }>("/watch_later", { signal }),
    select: (data) => new Set(data.items),
    staleTime: 60_000,
  });
  const toggle = useMutation({
    mutationFn: ({ item, save }: { item: Saveable; save: boolean }) =>
      save
        ? api.post("/watch_later", { item_type: item.kind, item_id: item.id })
        : api.delete(`/watch_later?item_type=${item.kind}&item_id=${item.id}`),
    onSuccess: (_data, { item, save }) => {
      toast.info(save ? `Saved ${item.title ?? "it"} to Watch later` : `Removed ${item.title ?? "it"} from Watch later`);
      void queryClient.invalidateQueries({ queryKey: keys.watchLater.all });
      void queryClient.invalidateQueries({ queryKey: keys.playlists.all });
    },
  });
  const isSaved = (item: { kind: string; id: string }) => saved.data?.has(`${item.kind}:${item.id}`) ?? false;
  return { isSaved, toggle: (item: Saveable) => toggle.mutate({ item, save: !isSaved(item) }) };
}
