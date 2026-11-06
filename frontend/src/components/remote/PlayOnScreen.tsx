import { useMutation, useQuery } from "@tanstack/react-query";
import { Cast } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { Button } from "@/components/ui/Button";
import { Menu } from "@/components/ui/Menu";
import { toast } from "@/components/ui/Toast";
import type { PlayableKind, RemoteDevice } from "@/types";

/**
 * Play this on another screen (PROPOSAL §11 Phase 6): the TVs and browsers
 * listening right now. Shown only when there's one to send to.
 */
export function PlayOnScreen({ kind, id }: { kind: PlayableKind; id: string }) {
  const devices = useQuery({
    queryKey: keys.remote.devices(),
    queryFn: ({ signal }) => api.get<RemoteDevice[]>("/remote/devices", { signal }),
    refetchInterval: 30_000,
    enabled: kind !== "extra",
  });
  const send = useMutation({
    mutationFn: (device: RemoteDevice) => api.post(`/remote/devices/${device.id}/commands`, { kind: "play", playable_type: kind, playable_id: id }),
    onSuccess: (_data, device) => toast.info(`Sent to ${device.name}.`),
  });
  if (!devices.data?.length) return null;

  return (
    <Menu label="Play on another screen" icon={<Cast className="h-4 w-4" aria-hidden />} align="left">
      <div className="space-y-1">
        {devices.data.map((device) => (
          <Button key={device.id} variant="ghost" size="sm" className="w-full justify-start" onClick={() => send.mutate(device)} disabled={send.isPending}>
            {device.name}
            {device.now_playing ? <span className="truncate text-xs text-muted">· {device.now_playing.title}</span> : null}
          </Button>
        ))}
      </div>
    </Menu>
  );
}
