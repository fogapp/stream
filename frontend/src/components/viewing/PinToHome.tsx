import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Pin, PinOff } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { Button } from "@/components/ui/Button";

/** A collection or playlist as a row of its own on this profile's Home (PROPOSAL §7.1). */
export function PinToHome({ kind, id, pinned, onChange }: { kind: "collection" | "playlist"; id: string; pinned: boolean; onChange: () => void }) {
  const queryClient = useQueryClient();
  const toggle = useMutation({
    mutationFn: () => (pinned ? api.delete(`/home/pin?kind=${kind}&id=${id}`) : api.post("/home/pin", { kind, id })),
    onSuccess: () => {
      onChange();
      void queryClient.invalidateQueries({ queryKey: keys.home.all });
    },
  });
  const Icon = pinned ? PinOff : Pin;
  return (
    <Button variant="ghost" onClick={() => toggle.mutate()} disabled={toggle.isPending} aria-pressed={pinned}>
      <Icon className="h-4 w-4" aria-hidden />
      {pinned ? "Unpin from Home" : "Pin to Home"}
    </Button>
  );
}
