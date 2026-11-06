import { useSearchParams } from "react-router-dom";
import { useOptimizerStatus } from "@/hooks/useOptimizerStatus";
import { PageHeader } from "@/components/layout/PageHeader";
import { Tabs } from "@/components/ui/Tabs";
import { ConvertingTable } from "@/components/playback/ConvertingTable";
import { HealthStrip } from "@/components/playback/HealthStrip";
import { LearnedTable } from "@/components/playback/LearnedTable";
import { OptimizerPanel } from "@/components/playback/OptimizerPanel";
import { SessionsTable } from "@/components/playback/SessionsTable";
import { OptimizedTable, QueueTable } from "@/components/playback/VersionTables";
import { WeekDetails } from "@/components/playback/WeekDetails";
import { PLAYBACK_TABS, type PlaybackTab } from "@/types";

function isTab(value: string | null): value is PlaybackTab {
  return PLAYBACK_TABS.some((tab) => tab === value);
}

/**
 * The Playback page (PROPOSAL §7.6): whether playback is healthy and what
 * to do if it isn't, then tables to act from — every press of Play and
 * why it went the way it did, the files still converted live, what's
 * scheduled to optimize, what has been, and what plays have taught. The tab and each table's
 * filters live in the URL, so a health card can open the rows it counted.
 */
export function PlaybackDecisions() {
  const [params, setParams] = useSearchParams();
  const raw = params.get("tab");
  const tab: PlaybackTab = isTab(raw) ? raw : "sessions";
  const status = useOptimizerStatus();
  const queued = status.data ? status.data.queue.queued + status.data.encoding.length : null;

  const tabs = [
    { key: "sessions", label: "Sessions" },
    { key: "converting", label: "Needs converting" },
    { key: "queue", label: queued ? `Queue (${queued})` : "Queue" },
    { key: "optimized", label: "Optimized" },
    { key: "learned", label: "Learned" },
  ] as const;

  return (
    <>
      <PageHeader title="Playback" description="Is playback healthy, and why did each play go the way it did? Then do something about it." />
      <div className="space-y-6 px-4 py-4 sm:px-6 lg:px-8 lg:py-6">
        <HealthStrip />
        <WeekDetails />
        <section className="space-y-4">
          <div className="border-b border-border">
            {/* A new tab starts unfiltered: each table's filters are its own. */}
            <Tabs tabs={tabs} active={tab} onChange={(next) => setParams(next === "sessions" ? {} : { tab: next })} label="Playback tables" />
          </div>
          {tab === "queue" || tab === "optimized" ? <OptimizerPanel /> : null}
          {tab === "sessions" ? <SessionsTable /> : null}
          {tab === "converting" ? <ConvertingTable /> : null}
          {tab === "queue" ? <QueueTable encoding={status.data?.state === "encoding"} /> : null}
          {tab === "optimized" ? <OptimizedTable /> : null}
          {tab === "learned" ? <LearnedTable /> : null}
        </section>
      </div>
    </>
  );
}
