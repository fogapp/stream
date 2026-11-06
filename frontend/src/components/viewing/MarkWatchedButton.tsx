import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Eye, EyeOff } from "lucide-react";
import { api, apiErrorMessage } from "@/api/client";
import { refreshWatched } from "@/lib/watched";
import { IconButton } from "@/components/ui/IconButton";
import { toast } from "@/components/ui/Toast";

/** Mark it watched (or back) from the card, without opening its "…". */
export function MarkWatchedButton({ item, className }: { item: { kind: "video"; id: string; title: string; watched: boolean }; className?: string }) {
  const queryClient = useQueryClient();
  const [pending, setPending] = useState(false);
  const watched = !item.watched;
  const mark = () => {
    setPending(true);
    api
      .post("/watch_states", { playable_type: item.kind, playable_id: item.id, watched })
      .then(() => {
        refreshWatched(queryClient, { kind: item.kind, id: item.id, watched });
        toast.info(`${item.title}: marked ${watched ? "watched" : "unwatched"}`);
      })
      .catch((error: unknown) => toast.error(apiErrorMessage(error, "That didn't go through.")))
      .finally(() => setPending(false));
  };
  const Icon = item.watched ? EyeOff : Eye;
  return (
    <IconButton label={item.watched ? "Mark as unwatched" : "Mark as watched"} onClick={mark} disabled={pending} className={className}>
      <Icon className="h-4 w-4" aria-hidden />
    </IconButton>
  );
}
