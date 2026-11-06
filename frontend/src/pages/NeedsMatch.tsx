import { useState, type FormEvent } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { Film, FolderTree, Search, Tv } from "lucide-react";
import { api } from "@/api/client";
import { useAuth } from "@/hooks/useAuth";
import { useFormMutation } from "@/hooks/useFormMutation";
import { keys } from "@/lib/queryKeys";
import { tmdbImage } from "@/lib/tmdb";
import { PageHeader } from "@/components/layout/PageHeader";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { FormError } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import type { MatchCandidate, MatchTitle, MultiFolderShow } from "@/types";

/**
 * Needs match (PROPOSAL §5.2): titles the matcher wouldn't guess at, with the
 * candidates it considered and why each fell short. An admin picks; the pick
 * refetches metadata and, for a show, refiles its episodes.
 */
export function NeedsMatch() {
  const titles = useQuery({ queryKey: keys.matches.list(), queryFn: ({ signal }) => api.get<MatchTitle[]>("/matches", { signal }) });

  return (
    <>
      <PageHeader
        title="Needs match"
        description="Stream wasn't sure what these are. They still play under their file names; pick the right title to get artwork and details."
      />
      <div className="space-y-4 px-4 py-4 sm:px-6 lg:px-8 lg:py-6">
        <QueryState query={titles} errorMessage="Could not load the Needs match queue.">
          {(list) =>
            list.length === 0 ? (
              <EmptyState title="Nothing needs matching" description="Every title in your libraries has been identified." />
            ) : (
              list.map((title) => <MatchCard key={`${title.kind}-${title.id}`} title={title} />)
            )
          }
        </QueryState>
        <FiledTwice />
      </div>
    </>
  );
}

/**
 * Shows filed from more than one folder: Stream already plays them as one
 * show, but the share holds a copy someone may want to remove in Sonarr.
 */
function FiledTwice() {
  const shows = useQuery({ queryKey: keys.matches.folders(), queryFn: ({ signal }) => api.get<MultiFolderShow[]>("/matches/folders", { signal }) });
  return (
    <QueryState query={shows} errorMessage="Could not load the shows filed from several folders.">
      {(list) =>
        list.length === 0 ? null : (
          <Card>
            <CardHeader
              title={
                <span className="flex items-center gap-2">
                  <FolderTree className="h-4 w-4 text-muted" aria-hidden />
                  Filed in more than one folder
                </span>
              }
              description="Each plays as one show, with every copy of an episode to choose from. To keep one copy, remove the others in Sonarr."
            />
            <CardBody>
              <ul className="divide-y divide-border">
                {list.map((show) => (
                  <li key={show.id} className="space-y-1 py-2">
                    <Link to={`/show/${show.id}`} className="font-medium text-foreground hover:underline">
                      {show.title}
                      {show.year ? <span className="font-normal text-muted"> ({show.year})</span> : null}
                    </Link>
                    <span className="ml-2 text-xs text-muted">{show.library.name}</span>
                    <ul>
                      {show.folders.map((row) => (
                        <li key={row.folder} className="break-all font-mono text-xs text-muted">
                          {row.paths.join(", ") || row.folder}
                        </li>
                      ))}
                    </ul>
                  </li>
                ))}
              </ul>
            </CardBody>
          </Card>
        )
      }
    </QueryState>
  );
}

function MatchCard({ title }: { title: MatchTitle }) {
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const admin = user?.role === "admin";
  const [query, setQuery] = useState(title.title);
  const [year, setYear] = useState(title.year ? String(title.year) : "");
  const search = useFormMutation({
    mutationFn: () =>
      api.post<MatchCandidate[]>(`/matches/${title.kind}/${title.id}/search`, { query, year: year || undefined }),
    fallback: "The search didn't go through",
  });
  const choose = useMutation({
    mutationFn: (tmdbId: number) => api.post<MatchTitle>(`/matches/${title.kind}/${title.id}`, { tmdb_id: tmdbId }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: keys.matches.all }),
  });
  const candidates = search.data ?? title.candidates;
  const Icon = title.kind === "movie" ? Film : Tv;

  function onSearch(event: FormEvent) {
    event.preventDefault();
    search.mutate();
  }

  return (
    <Card>
      <CardHeader
        title={
          <span className="flex flex-wrap items-center gap-2">
            <Icon className="h-4 w-4 text-muted" aria-hidden />
            {title.title}
            {title.year ? <span className="font-normal text-muted">({title.year})</span> : null}
            <Badge tone={title.match_state === "needs_review" ? "warning" : "neutral"}>
              {title.match_state === "needs_review" ? "Unsure" : "Not found"}
            </Badge>
          </span>
        }
        description={
          <>
            {title.library.name}
            {title.folder ? ` · ${title.folder}` : ""}
            {title.match_summary ? ` — ${title.match_summary}` : ""}
          </>
        }
      />
      <CardBody className="space-y-4">
        {admin ? (
          <form onSubmit={onSearch} className="flex flex-col gap-2 sm:flex-row sm:items-end">
            <Input label="Search TMDB" value={query} onChange={(event) => setQuery(event.target.value)} />
            <Input
              label="Year"
              inputMode="numeric"
              className="sm:w-24"
              value={year}
              onChange={(event) => setYear(event.target.value.replace(/\D/g, "").slice(0, 4))}
            />
            <Button type="submit" variant="secondary" disabled={search.isPending || !query.trim()}>
              <Search className="h-4 w-4" aria-hidden />
              Search
            </Button>
          </form>
        ) : null}
        <FormError message={search.errorMessage} />
        {candidates.length === 0 ? (
          <p className="text-sm text-muted">No candidates. Try a different spelling or drop the year.</p>
        ) : (
          <ul className="grid gap-3 md:grid-cols-2">
            {candidates.map((candidate) => (
              <CandidateRow
                key={candidate.tmdb_id}
                candidate={candidate}
                onChoose={admin ? () => choose.mutate(candidate.tmdb_id) : undefined}
                pending={choose.isPending && choose.variables === candidate.tmdb_id}
              />
            ))}
          </ul>
        )}
      </CardBody>
    </Card>
  );
}

function CandidateRow({
  candidate,
  onChoose,
  pending,
}: {
  candidate: MatchCandidate;
  onChoose?: () => void;
  pending: boolean;
}) {
  const poster = tmdbImage(candidate.poster_path, 92);
  return (
    <li className="flex gap-3 rounded-[var(--radius-card)] border border-border bg-surface p-3">
      <div className="aspect-[2/3] w-16 shrink-0 overflow-hidden rounded-[var(--radius-control)] bg-surface-raised">
        {poster ? <img src={poster} alt="" loading="lazy" className="h-full w-full object-cover" /> : null}
      </div>
      <div className="min-w-0 flex-1 space-y-1">
        <p className="font-medium text-foreground">
          {candidate.title} {candidate.year ? <span className="text-muted">({candidate.year})</span> : null}
        </p>
        <p className="text-xs text-muted">
          {Math.round(candidate.score * 100)}% · {candidate.reasons.join(" · ")}
          {candidate.vote_count === undefined ? null : ` · ${candidate.vote_count.toLocaleString()} TMDB votes`}
        </p>
        {candidate.overview ? <p className="line-clamp-2 text-xs text-muted">{candidate.overview}</p> : null}
        {onChoose ? (
          <Button size="sm" variant="secondary" onClick={onChoose} disabled={pending}>
            {pending ? "Matching…" : "This one"}
          </Button>
        ) : null}
      </div>
    </li>
  );
}
