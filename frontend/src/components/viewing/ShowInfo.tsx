import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { api } from "@/api/client";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { Dialog } from "@/components/ui/Dialog";
import { Fact, FactList } from "@/components/ui/FactList";
import { FormError } from "@/components/ui/Form";
import { QueryState } from "@/components/ui/PageState";
import { useFormMutation } from "@/hooks/useFormMutation";
import { formatBytes } from "@/lib/bytes";
import { MATCH_STATE_LABELS, MEDIA_FILE_STATE_LABELS, MEDIA_FILE_STATE_TONES } from "@/lib/libraries";
import { keys } from "@/lib/queryKeys";
import type { MatchTitle, ShowInfo } from "@/types";
import { plural } from "@/lib/format";

/** Info: the raw record behind a show, for an admin (its folder, ids, match, and every file). */
export function ShowInfoDialog({ showId, onClose }: { showId: string; onClose: () => void }) {
  const info = useQuery({ queryKey: keys.shows.info(showId), queryFn: ({ signal }) => api.get<ShowInfo>(`/shows/${showId}/info`, { signal }) });
  return (
    <Dialog label="Show info" onClose={onClose} className="max-h-[90vh] max-w-3xl overflow-y-auto">
      <QueryState query={info} errorMessage="Could not load this show's info.">
        {(show) => <ShowInfoBody show={show} onClose={onClose} />}
      </QueryState>
    </Dialog>
  );
}

function ShowInfoBody({ show, onClose }: { show: ShowInfo; onClose: () => void }) {
  const [allFiles, setAllFiles] = useState(false);
  const files = allFiles ? show.files : show.files.slice(0, 50);
  return (
    <div className="space-y-6 pr-6 text-sm">
      <div>
        <h2 className="text-lg font-semibold text-foreground">{show.title}</h2>
        <p className="font-mono text-xs text-muted">{show.id}</p>
      </div>

      <FactList>
        <Fact label="Library" value={show.library.name ?? "—"} mono={false} />
        <Fact label="Year" value={show.year ?? "—"} />
        <Fact label="TMDB" value={show.ids.tmdb_id ?? "—"} />
        <Fact label="TVDB" value={show.ids.tvdb_id ?? "—"} />
        <Fact label="IMDb" value={show.ids.imdb_id ?? "—"} />
        <Fact
          label="Match"
          value={`${MATCH_STATE_LABELS[show.match.state]}${show.match.score !== null ? ` · ${Math.round(show.match.score * 100)}%` : ""}`}
          hint={show.match.summary}
          mono={false}
        />
        <Fact
          label="Contents"
          value={[plural(show.counts.seasons, "season"), plural(show.counts.episodes, "episode"), plural(show.counts.files, "file")].join(" · ")}
          hint={show.counts.missing_files > 0 ? `${show.counts.missing_files} missing` : undefined}
          mono={false}
        />
        <Fact label="Added" value={new Date(show.created_at).toLocaleString()} mono={false} />
      </FactList>

      <FiledFrom show={show} />

      {show.look_alikes.length > 0 ? (
        <section className="space-y-2">
          <h3 className="font-medium text-foreground">Looks like the same show</h3>
          <p className="text-xs text-muted">Filed separately because each comes from its own folder.</p>
          <ul className="space-y-1">
            {show.look_alikes.map((other) => (
              <li key={other.id}>
                <Link to={`/show/${other.id}`} onClick={onClose} className="text-foreground hover:underline">
                  {other.title}
                  {other.year ? ` (${other.year})` : ""}
                </Link>
                <span className="ml-2 break-all font-mono text-xs text-muted">
                  {other.library ? `${other.library} › ` : ""}
                  {other.folder}
                  {other.tmdb_id ? ` · TMDB ${other.tmdb_id}` : ""}
                </span>
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      <section className="space-y-2">
        <h3 className="font-medium text-foreground">Folders its files are in</h3>
        <ul className="space-y-1">
          {show.directories.map((directory) => (
            <li key={directory.path} className="flex gap-3">
              <span className="min-w-0 flex-1 break-all font-mono text-xs text-foreground">{directory.path}</span>
              <span className="shrink-0 text-xs tabular-nums text-muted">{directory.files}</span>
            </li>
          ))}
        </ul>
      </section>

      <section className="space-y-2">
        <h3 className="font-medium text-foreground">Files</h3>
        <ul className="divide-y divide-border">
          {files.map((file) => (
            <li key={`${file.id}-${file.episode.id}`} className="flex items-start gap-3 py-1.5">
              <span className="w-16 shrink-0 font-mono text-xs text-muted">{file.episode.code}</span>
              <Link to={`/files/${file.id}`} onClick={onClose} className="min-w-0 flex-1 break-all font-mono text-xs text-foreground hover:underline">
                {file.path}
              </Link>
              <span className="shrink-0 text-xs tabular-nums text-muted">{formatBytes(file.size)}</span>
              {file.state !== "probed" ? <Badge tone={MEDIA_FILE_STATE_TONES[file.state]}>{MEDIA_FILE_STATE_LABELS[file.state]}</Badge> : null}
            </li>
          ))}
        </ul>
        {show.files.length > files.length ? (
          <Button variant="ghost" size="sm" onClick={() => setAllFiles(true)}>
            Show all {show.files.length} files
          </Button>
        ) : null}
      </section>
    </div>
  );
}

/**
 * The folders a show is filed from. Copies of one show in two folders share
 * it; "Not this show" undoes that (or a wrong match) by sending the folder
 * back to Needs match, where Stream won't pick this title for it again.
 */
function FiledFrom({ show }: { show: ShowInfo }) {
  const queryClient = useQueryClient();
  const reject = useFormMutation({
    mutationFn: (folder: string) => api.post<MatchTitle>(`/matches/show/${show.id}/reject`, { folder }),
    fallback: "That folder couldn't be sent back",
    onSuccess: () =>
      Promise.all([
        queryClient.invalidateQueries({ queryKey: keys.shows.all }),
        queryClient.invalidateQueries({ queryKey: keys.matches.all }),
      ]),
  });
  const several = show.folders.length > 1;
  return (
    <section className="space-y-2">
      <h3 className="font-medium text-foreground">Filed from {several ? `${show.folders.length} folders` : "its folder"}</h3>
      {several ? (
        <p className="text-xs text-muted">
          Copies of the same show, combined into one. Each episode plays the best copy; to keep only one, remove the others in Sonarr.
        </p>
      ) : null}
      <ul className="space-y-2">
        {show.folders.map((row) => (
          <li key={row.folder} className="flex flex-wrap items-center gap-3">
            <span className="min-w-0 flex-1 break-all font-mono text-xs text-foreground">{row.paths.join(", ") || row.folder}</span>
            <ConfirmButton
              variant="ghost"
              question={several ? `File ${row.folder} on its own?` : "Send it back to Needs match?"}
              disabled={reject.isPending}
              onConfirm={() => reject.mutate(row.folder)}
            >
              Not {show.title}
            </ConfirmButton>
          </li>
        ))}
      </ul>
      <FormError message={reject.errorMessage} />
    </section>
  );
}

