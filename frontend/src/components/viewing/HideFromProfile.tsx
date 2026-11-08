import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "react-router-dom";
import { Ban } from "lucide-react";
import { api, apiErrorMessage } from "@/api/client";
import { CATALOG_KEYS } from "@/hooks/useCatalogVersion";
import { useProfile } from "@/hooks/useProfile";
import { keys } from "@/lib/queryKeys";
import type { ButtonSize } from "@/components/ui/Button";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { toast } from "@/components/ui/Toast";
import type { HideableKind } from "@/types";

type Hideable = { kind: HideableKind; id: string; title: string };

/**
 * What a title leaving a profile changes: every list of titles and search
 * (the catalog's), the Grid, subscriptions, playlists and Watch later that
 * held it, and the profile's own list of what's hidden.
 */
export function hiddenTitleKeys(profileId: string) {
  return [...CATALOG_KEYS, keys.live.all, keys.subscriptions.all, keys.playlists.all, keys.watchLater.all, keys.profiles.content(profileId)];
}

/**
 * Hides a title from the current profile; `null` where that isn't offered
 * (no profile yet, or a kid's). `onHidden` runs first, so a page the
 * profile can no longer open can be left before everything refetches.
 */
export function useHideFromProfile(item: Hideable, onHidden?: () => void) {
  const { profile } = useProfile();
  const queryClient = useQueryClient();
  const hide = useMutation({
    mutationFn: (id: string) => api.put(`/profiles/${id}/content/hidden`, { kind: item.kind, id: item.id, hidden: true }),
    onSuccess: (_data, profileId) => {
      onHidden?.();
      for (const queryKey of hiddenTitleKeys(profileId)) void queryClient.invalidateQueries({ queryKey });
      toast.info(`${item.title} is hidden from ${profile?.name ?? "this profile"}. Settings › Viewing brings it back.`);
    },
    onError: (error) => toast.error(apiErrorMessage(error, `Couldn't hide ${item.title}.`)),
  });
  if (!profile || profile.kind === "kid") return null;
  return { profileName: profile.name, hide: () => hide.mutate(profile.id), pending: hide.isPending };
}

/**
 * "Hide from me": the title leaves this profile everywhere — rows, search,
 * Grid, its own page — until it's brought back from Settings › Viewing
 * (or an admin's Settings › Profiles). Not offered to a kid profile.
 */
export function HideFromProfile({ item, size = "lg" }: { item: Hideable; size?: ButtonSize }) {
  const navigate = useNavigate();
  // Off this page first: it's one the profile can no longer open.
  const hiding = useHideFromProfile(item, () => navigate("/", { replace: true }));
  if (!hiding) return null;

  return (
    <ConfirmButton variant="ghost" size={size} question={`Hide from ${hiding.profileName} everywhere?`} disabled={hiding.pending} onConfirm={hiding.hide}>
      <Ban className="h-4 w-4" aria-hidden />
      Hide from me
    </ConfirmButton>
  );
}
