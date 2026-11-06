import { useQuery } from "@tanstack/react-query";
import { formatBytes } from "@/lib/bytes";
import { formatUptime } from "@/lib/uptime";
import { aboutQuery } from "@/lib/queries";
import { CopyField } from "@/components/ui/CopyField";
import { Fact, FactList } from "@/components/ui/FactList";
import { ErrorState, LoadingState } from "@/components/ui/PageState";
import { SectionHeader } from "@/components/ui/SectionHeader";

/**
 * Settings → About (hub:frontend/src/pages/settings/About.tsx): which build
 * is running, and — because Stream is a fog app on a box someone else may
 * have set up — what it is running on. The revision is the fact people
 * actually come for, so it gets the copy button.
 */
export function About() {
  const about = useQuery(aboutQuery());

  if (about.isPending) return <LoadingState />;
  if (about.isError) {
    return <ErrorState message="Could not load instance details." onRetry={() => about.refetch()} />;
  }

  const info = about.data;
  const booted = new Date(info.booted_at);

  return (
    <div className="space-y-8">
      <section className="space-y-4">
        <SectionHeader title="Version" description="The build of Stream this household is running." />
        <div>
          <p className="mb-1 text-xs uppercase tracking-wide text-muted">Revision</p>
          {info.git_sha === "unknown" ? (
            <p className="font-mono text-sm text-muted">unknown</p>
          ) : (
            <CopyField value={info.git_sha} />
          )}
        </div>
        <FactList>
          <Fact label="Environment" value={info.environment} />
          <Fact label="Server started" value={`${booted.toLocaleString()} · up ${formatUptime(booted)}`} mono={false} />
          <Fact label="Time zone" value={info.time_zone} />
          <Fact label="Ruby" value={info.ruby_version} />
          <Fact label="Rails" value={info.rails_version} />
          <Fact label="PostgreSQL" value={info.postgres_version ?? "unknown"} />
        </FactList>
      </section>

      <section className="space-y-4">
        <SectionHeader title="This server" description="The machine Stream is running on, as the process sees it." />
        <FactList>
          <Fact label="Hostname" value={info.machine.hostname} />
          <Fact label="Platform" value={`${info.machine.os} · ${info.machine.arch}`} mono={false} />
          <Fact label="Kernel" value={info.machine.kernel} />
          <Fact label="CPUs" value={String(info.machine.cpus)} />
          <Fact label="Memory" value={formatBytes(info.machine.memory_total_bytes)} />
          <Fact
            label="Process"
            value={`pid ${info.machine.pid}${info.machine.user ? ` as ${info.machine.user}` : ""}${info.machine.containerized ? ", in a container" : ""}`}
            mono={false}
          />
        </FactList>
      </section>

      <section className="space-y-4">
        <SectionHeader title="Paths" description="Where this instance keeps its own state. Download and delivery folders are configured per client and per library." />
        <FactList className="md:grid-cols-2">
          <Fact label="State directory" value={info.storage.state_dir} />
          <Fact
            label="State disk"
            value={
              info.storage.total_bytes === null
                ? "unknown"
                : `${formatBytes(info.storage.free_bytes)} free of ${formatBytes(info.storage.total_bytes)}`
            }
            mono={false}
          />
        </FactList>
      </section>
    </div>
  );
}
