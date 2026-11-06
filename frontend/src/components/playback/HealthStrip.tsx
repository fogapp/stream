import { useQuery } from "@tanstack/react-query";
import { api } from "@/api/client";
import { HEALTH_STATUS_LABELS, HEALTH_STATUS_TONES, healthLink } from "@/lib/health";
import { keys } from "@/lib/queryKeys";
import { HealthCard } from "@/components/ui/HealthCard";
import { ErrorState, LoadingState } from "@/components/ui/PageState";
import type { PlaybackHealth } from "@/types";

/**
 * The top of the Playback page: is playback healthy, and is there
 * something to do? One card per check (Playback::Health), each opening the
 * tab and filters that show what it counted.
 */
export function HealthStrip() {
  const health = useQuery({
    queryKey: keys.playbackDecisions.health(),
    queryFn: ({ signal }) => api.get<PlaybackHealth>("/playback_decisions/health", { signal }),
    refetchInterval: 60_000,
  });

  if (health.isPending) return <LoadingState label="Checking playback…" />;
  if (health.isError) return <ErrorState message="Could not check playback's health." onRetry={() => void health.refetch()} />;

  return (
    <section aria-label="Playback health" className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
      {health.data.checks.map((check) => (
        <HealthCard
          key={check.key}
          title={check.title}
          verdict={HEALTH_STATUS_LABELS[check.status]}
          tone={HEALTH_STATUS_TONES[check.status]}
          metric={check.metric}
          detail={check.detail}
          action={check.action}
          to={healthLink(check.link)}
        />
      ))}
    </section>
  );
}
