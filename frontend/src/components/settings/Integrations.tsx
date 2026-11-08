import { useAuth } from "@/hooks/useAuth";
import { ArrCard } from "@/components/settings/integrations/ArrCard";
import { HookCard } from "@/components/settings/integrations/HookCard";
import { ImmichCard } from "@/components/settings/integrations/ImmichCard";
import { MlbCard } from "@/components/settings/integrations/MlbCard";
import { NbaCard } from "@/components/settings/integrations/NbaCard";
import { OpenSubtitlesCard } from "@/components/settings/integrations/OpenSubtitlesCard";
import { TmdbCard } from "@/components/settings/integrations/TmdbCard";
import { TraktCard } from "@/components/settings/integrations/TraktCard";
import { WhisperCard } from "@/components/settings/integrations/WhisperCard";

/** Settings › Integrations: the services Stream talks to. TMDB for everyone; the rest are an admin's. */
export function Integrations() {
  const { user } = useAuth();
  const admin = user?.role === "admin";
  return (
    <div className="space-y-6">
      <TmdbCard />
      {admin ? (
        <>
          <ArrCard />
          <HookCard />
          <ImmichCard />
          <TraktCard />
          <OpenSubtitlesCard />
          <WhisperCard />
          <MlbCard />
          <NbaCard />
        </>
      ) : null}
    </div>
  );
}
