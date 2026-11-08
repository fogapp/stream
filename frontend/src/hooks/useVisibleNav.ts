import { useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { useProfile } from "@/hooks/useProfile";
import { visibleNav } from "@/lib/nav";
import { offlineSupported } from "@/lib/offline/downloads";
import { baseballQuery, basketballQuery } from "@/lib/queries";

/**
 * The destinations (lib/nav) offered to whoever is signed in, on the
 * profile watching. `pending` while what a feature waits on isn't known yet,
 * so the sidebar can hold its rows rather than have them arrive one by one.
 */
export function useVisibleNav() {
  const { user } = useAuth();
  const { profile } = useProfile();
  const baseball = useQuery(baseballQuery());
  const basketball = useQuery(basketballQuery());
  const role = user?.role;
  const kind = profile?.kind;
  const hasBaseball = baseball.data?.available === true;
  const hasBasketball = basketball.data?.available === true;
  // The same array while nothing it depends on changes, for the palette's memo.
  const entries = useMemo(
    () =>
      visibleNav(role ? { role } : null, kind ? { kind } : null, { baseball: hasBaseball, basketball: hasBasketball, offline: offlineSupported() }),
    [role, kind, hasBaseball, hasBasketball],
  );
  return { entries, pending: baseball.isPending || basketball.isPending };
}
