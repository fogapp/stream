import { useQuery } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { Plus } from "lucide-react";
import { api } from "@/api/client";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/Button";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import { keys } from "@/lib/queryKeys";
import type { Station } from "@/types";

/** Grid's channels, for an admin to make and program (PROPOSAL §7.7). */
export function LiveChannels() {
  const stations = useQuery({ queryKey: keys.live.stations(true), queryFn: ({ signal }) => api.get<Station[]>("/stations?hidden=1", { signal }) });
  const newButton = (
    <Link to="/live/channels/new">
      <Button>
        <Plus className="h-4 w-4" aria-hidden />
        New channel
      </Button>
    </Link>
  );
  return (
    <div className="space-y-6 px-4 py-6 sm:px-6 lg:px-8">
      <PageHeader title="Channels" description="Each channel's number, name and what it airs. Saving one rebuilds its schedule from the end of what's on." actions={newButton} />
      <QueryState
        query={stations}
        errorMessage="The channels couldn't be loaded."
        empty={<EmptyState title="No channels yet" description="A channel airs shows and films from the library on a schedule." action={newButton} />}
      >
        {(list) => (
          <ul className="divide-y divide-border overflow-hidden rounded-[var(--radius-card)] border border-border bg-surface">
            {list.map((station) => (
              <li key={station.id}>
                <Link to={`/live/channels/${station.id}`} className="flex items-center gap-4 px-4 py-3 hover:bg-surface-raised">
                  <span className="w-14 font-mono text-lg font-semibold tabular-nums">{station.number}</span>
                  <span className="min-w-0 flex-1 truncate font-medium">{station.name}</span>
                  {station.call_sign ? <span className="text-sm text-muted">{station.call_sign}</span> : null}
                </Link>
              </li>
            ))}
          </ul>
        )}
      </QueryState>
    </div>
  );
}
