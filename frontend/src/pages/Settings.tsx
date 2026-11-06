import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useSearchParams } from "react-router-dom";
import { ChevronRight } from "lucide-react";
import { api } from "@/api/client";
import { useAuth } from "@/hooks/useAuth";
import { cn } from "@/lib/cn";
import { keys } from "@/lib/queryKeys";
import { PageHeader } from "@/components/layout/PageHeader";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { QueryState } from "@/components/ui/PageState";
import { SectionHeader } from "@/components/ui/SectionHeader";
import { Tabs } from "@/components/ui/Tabs";
import { About } from "@/components/settings/About";
import { ApiTokens } from "@/components/settings/ApiTokens";
import { General } from "@/components/settings/General";
import { Integrations } from "@/components/settings/Integrations";
import { Libraries } from "@/components/settings/Libraries";
import { PlexImport } from "@/components/settings/PlexImport";
import { Profiles } from "@/components/settings/Profiles";
import { Transcoders } from "@/components/settings/Transcoders";
import { Users } from "@/components/settings/Users";
import { Viewing } from "@/components/settings/Viewing";
import { Youtube } from "@/components/settings/Youtube";
import type { ManagedJob } from "@/types";
import { JOB_RUN_STATUS_LABELS, JOB_RUN_STATUS_TONES } from "@/lib/jobs";

/** Each section: its key in the URL, its tab, what it shows, and whether only admins see it. */
const TABS = [
  { key: "general", label: "General", Panel: General, admin: false },
  { key: "viewing", label: "Viewing", Panel: Viewing, admin: false },
  { key: "profiles", label: "Profiles", Panel: Profiles, admin: true },
  { key: "libraries", label: "Libraries", Panel: Libraries, admin: false },
  { key: "integrations", label: "Integrations", Panel: Integrations, admin: false },
  { key: "plex", label: "Import from Plex", Panel: PlexImport, admin: true },
  { key: "youtube", label: "YouTube", Panel: Youtube, admin: true },
  { key: "transcoders", label: "Transcoders", Panel: Transcoders, admin: true },
  { key: "users", label: "Users", Panel: Users, admin: false },
  { key: "tokens", label: "API tokens", Panel: ApiTokens, admin: false },
  { key: "jobs", label: "Background jobs", Panel: BackgroundJobs, admin: true },
  { key: "about", label: "About", Panel: About, admin: false },
] as const;
type SettingsTab = (typeof TABS)[number]["key"];

function isTab(value: string | null): value is SettingsTab {
  return TABS.some((tab) => tab.key === value);
}

export function Settings() {
  // The tab lives in the URL so "check Background jobs" can be a link and a
  // refresh stays where you were.
  const [params, setParams] = useSearchParams();
  const { user } = useAuth();
  // Admin-only sections aren't offered to anyone who'd only get a 403.
  const tabs = TABS.filter((tab) => user?.role === "admin" || !tab.admin);
  const raw = params.get("tab");
  const active: SettingsTab = isTab(raw) && tabs.some((tab) => tab.key === raw) ? raw : "general";
  const Panel = TABS.find((tab) => tab.key === active)?.Panel ?? General;

  function switchTab(tab: SettingsTab) {
    setParams(tab === "general" ? {} : { tab }, { replace: true });
  }

  return (
    <>
      <PageHeader
        title="Settings"
        description="Libraries, who can sign in, API tokens, background jobs, and what this server is running."
      />
      <div className="border-b border-border px-4 sm:px-6 lg:px-8">
        <Tabs tabs={tabs} active={active} onChange={switchTab} label="Settings sections" />
      </div>
      <div className="space-y-6 px-4 py-4 sm:px-6 lg:px-8 lg:py-6">
        <Panel />
      </div>
    </>
  );
}

function BackgroundJobs() {
  const queryClient = useQueryClient();
  const jobs = useQuery({
    queryKey: keys.jobs.list(),
    queryFn: ({ signal }) => api.get<ManagedJob[]>("/background_jobs", { signal }),
    refetchInterval: 15_000,
  });

  const run = useMutation({
    mutationFn: (key: string) => api.post(`/background_jobs/${key}/run`),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: keys.jobs.all }),
  });

  return (
    <section className="space-y-2">
      <SectionHeader title="Background jobs" description="Trigger a run and see recent history." />
      <QueryState query={jobs} errorMessage="Could not load jobs.">
        {(managed) => (
          <div className="divide-y divide-border">
            {managed.map((job) => (
              <JobRow key={job.key} job={job} onRun={() => run.mutate(job.key)} running={run.isPending} />
            ))}
          </div>
        )}
      </QueryState>
    </section>
  );
}

function JobRow({ job, onRun, running }: { job: ManagedJob; onRun: () => void; running: boolean }) {
  const [open, setOpen] = useState(false);
  const latest = job.runs[0];

  return (
    <div>
      <button
        type="button"
        aria-expanded={open}
        onClick={() => setOpen((current) => !current)}
        className="flex w-full items-start justify-between gap-4 py-4 text-left"
      >
        <span className="flex min-w-0 items-start gap-2">
          <ChevronRight
            className={cn("mt-1 h-4 w-4 shrink-0 text-muted transition-transform", open && "rotate-90")}
            aria-hidden
          />
          <span className="min-w-0">
            <span className="block font-semibold text-foreground">{job.label}</span>
            <span className="mt-0.5 block text-sm text-muted">{job.description}</span>
          </span>
        </span>
        {latest ? (
          <Badge className="shrink-0" tone={JOB_RUN_STATUS_TONES[latest.status]}>
            {JOB_RUN_STATUS_LABELS[latest.status]}
          </Badge>
        ) : null}
      </button>
      {open ? (
        <div className="space-y-3 pb-4 pl-6">
          <Button variant="secondary" size="sm" onClick={onRun} disabled={running}>
            Run now
          </Button>
          {job.runs.length > 0 ? (
            <ul className="space-y-1">
              {job.runs.slice(0, 5).map((jobRun) => (
                <li key={jobRun.id} className="flex items-center gap-2 text-xs text-muted">
                  <Badge tone={JOB_RUN_STATUS_TONES[jobRun.status]}>{JOB_RUN_STATUS_LABELS[jobRun.status]}</Badge>
                  <span className="truncate">{jobRun.message ?? jobRun.error ?? "—"}</span>
                  <span className="ml-auto shrink-0">{new Date(jobRun.created_at).toLocaleString()}</span>
                </li>
              ))}
            </ul>
          ) : (
            <p className="text-sm text-muted">No runs yet.</p>
          )}
        </div>
      ) : null}
    </div>
  );
}
