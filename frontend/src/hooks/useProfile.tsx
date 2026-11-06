import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { api, profileTokenStore } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { ProfilePicker } from "@/components/profiles/ProfilePicker";
import { LoadingState } from "@/components/ui/PageState";
import { Navigate } from "react-router-dom";
import { rememberProfile } from "@/lib/offline/store";
import { offlineSupported } from "@/lib/offline/downloads";
import type { CurrentProfile, ProfileInfo } from "@/types";

interface ProfileValue {
  profile: ProfileInfo | null;
  deviceDefaultId: string | null;
  /** Open "Who's watching?". */
  switchProfile: () => void;
  /** The server said yes (PIN and all): watch as this profile from now on. */
  adopt: (token: string) => void;
}

const ProfileContext = createContext<ProfileValue | null>(null);

/**
 * Who's watching (PROPOSAL §7.4). The picker shows when a household has
 * more than one profile and this browser hasn't chosen (and its device has
 * no default); switching forgets every per-profile answer the app holds.
 */
export function ProfileProvider({ children, onSwitch }: { children: ReactNode; onSwitch?: () => void }) {
  const queryClient = useQueryClient();
  const [picking, setPicking] = useState(false);
  const current = useQuery({ queryKey: keys.profiles.current(), queryFn: ({ signal }) => api.get<CurrentProfile>("/profiles/current", { signal }) });
  // Asked once, when the app opens: a profile added later (in Settings, say)
  // mustn't throw whoever's using the app out to the picker.
  const [askedAtStart, setAskedAtStart] = useState<boolean | null>(null);
  useEffect(() => {
    if (askedAtStart === null && current.data) setAskedAtStart(current.data.needs_picker);
  }, [askedAtStart, current.data]);
  // Offline, this profile's downloads are the ones shown.
  useEffect(() => rememberProfile(current.data?.profile?.id ?? null), [current.data]);

  const adopt = useCallback(
    (token: string) => {
      profileTokenStore.set(token);
      setPicking(false);
      setAskedAtStart(false);
      onSwitch?.();
      // Everything cached was someone else's view.
      queryClient.clear();
    },
    [queryClient, onSwitch],
  );
  const switchProfile = useCallback(() => setPicking(true), []);

  const value = useMemo(
    () => ({ profile: current.data?.profile ?? null, deviceDefaultId: current.data?.device_default_id ?? null, switchProfile, adopt }),
    [current.data, switchProfile, adopt],
  );

  // No network (the query waits for one rather than failing): what's
  // downloaded still plays.
  if (current.isPending && current.fetchStatus === "paused" && offlineSupported()) return <Navigate to="/offline" replace />;
  if (current.isPending) return <LoadingState />;
  const mustPick = (askedAtStart ?? current.data?.needs_picker) === true;
  return (
    <ProfileContext.Provider value={value}>
      {picking || mustPick ? <ProfilePicker onChosen={adopt} onCancel={mustPick ? undefined : () => setPicking(false)} /> : children}
    </ProfileContext.Provider>
  );
}

export function useProfile(): ProfileValue {
  const context = useContext(ProfileContext);
  if (!context) throw new Error("useProfile outside ProfileProvider");
  return context;
}
