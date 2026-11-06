import { useState, type FormEvent } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { FolderPlus, RefreshCw, Trash2 } from "lucide-react";
import { api } from "@/api/client";
import { useAuth } from "@/hooks/useAuth";
import { useFormMutation } from "@/hooks/useFormMutation";
import { LIBRARY_KIND_OPTIONS, MEDIA_FILE_STATE_LABELS, MEDIA_FILE_STATE_TONES } from "@/lib/libraries";
import { keys } from "@/lib/queryKeys";
import { librariesQuery } from "@/lib/queries";
import { relativeTime } from "@/lib/time";
import { TestResultLine } from "@/components/settings/TestResultLine";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { FormError, FormFooter } from "@/components/ui/Form";
import { IconButton } from "@/components/ui/IconButton";
import { Input } from "@/components/ui/Input";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import { SectionHeader } from "@/components/ui/SectionHeader";
import { Select } from "@/components/ui/Select";
import { LIBRARY_KINDS, MEDIA_FILE_STATES, type FogLibrarySuggestion, type Library, type LibraryKind, type PathReport } from "@/types";

/** Settings › Libraries: which folders hold which kind of video (PROPOSAL §4.1, §5.1). */
export function Libraries() {
  const { user } = useAuth();
  const admin = user?.role === "admin";
  const [adding, setAdding] = useState(false);
  const libraries = useQuery({
    ...librariesQuery(),
    // A scan takes seconds to minutes; watch it land rather than making
    // someone refresh.
    refetchInterval: (query) => (query.state.data?.some((library) => library.scanning) ? 3_000 : false),
  });

  return (
    <section className="space-y-4">
      <SectionHeader
        title="Libraries"
        description="Point each library at the folders that hold it. Stream only ever reads them."
        actions={
          admin && !adding ? (
            <Button size="sm" onClick={() => setAdding(true)}>
              <FolderPlus className="h-4 w-4" aria-hidden />
              Add library
            </Button>
          ) : null
        }
      />
      {admin ? <FogSuggestions libraries={libraries.data ?? []} /> : null}
      {adding ? <LibraryForm onDone={() => setAdding(false)} /> : null}
      <QueryState query={libraries} errorMessage="Could not load libraries.">
        {(list) =>
          list.length === 0 && !adding ? (
            <EmptyState
              title="No libraries yet"
              description={
                admin
                  ? "Add one for your movies and one for your TV shows. Fog mounts them under /media."
                  : "An admin needs to add a library before there's anything to watch."
              }
            />
          ) : (
            <div className="space-y-4">
              {list.map((library) => (
                <LibraryCard key={library.id} library={library} admin={admin} />
              ))}
            </div>
          )
        }
      </QueryState>
    </section>
  );
}

/**
 * Folders fog mounts into Stream that no library reads yet: one click adds
 * each to the library of its kind, or makes it a library of its own. Empty
 * (and hidden) outside fog or once every folder is in a library.
 */
function FogSuggestions({ libraries }: { libraries: Library[] }) {
  const queryClient = useQueryClient();
  const suggestions = useQuery({
    queryKey: keys.libraries.fogSuggestions(),
    queryFn: ({ signal }) => api.get<FogLibrarySuggestion[]>("/libraries/fog_suggestions", { signal }),
  });
  const add = useMutation({
    mutationFn: (s: FogLibrarySuggestion) => {
      const target = libraries.find((library) => library.id === s.library_id);
      return target
        ? api.patch<Library>(`/libraries/${target.id}`, { library: { roots: [...target.roots, s.root] } })
        : api.post<Library>("/libraries", { library: { name: s.name, kind: s.kind, roots: [s.root] } });
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: keys.libraries.all }),
  });
  const list = suggestions.data ?? [];
  if (list.length === 0) return null;

  return (
    <Card>
      <CardHeader title="Folders from Fog" description="Fog mounts these into Stream, but no library reads them yet." />
      <CardBody className="space-y-2">
        {list.map((s) => (
          <div key={s.root} className="flex flex-wrap items-center justify-between gap-3">
            <span className="flex min-w-0 items-center gap-2">
              <span className="break-all font-mono text-sm text-foreground">{s.root}</span>
              <Badge>{LIBRARY_KIND_OPTIONS[s.kind].label}</Badge>
            </span>
            <Button size="sm" variant="secondary" onClick={() => add.mutate(s)} disabled={add.isPending}>
              {s.library_name ? `Add to ${s.library_name}` : `Add as ${s.name}`}
            </Button>
          </div>
        ))}
        {add.isError ? <p className="text-sm text-negative">Could not add the folder.</p> : null}
      </CardBody>
    </Card>
  );
}

function LibraryCard({ library, admin }: { library: Library; admin: boolean }) {
  const queryClient = useQueryClient();
  const [editing, setEditing] = useState(false);
  const invalidate = () => queryClient.invalidateQueries({ queryKey: keys.libraries.all });
  const scan = useMutation({ mutationFn: () => api.post(`/libraries/${library.id}/scan`), onSuccess: invalidate });
  const remove = useMutation({ mutationFn: () => api.delete(`/libraries/${library.id}`), onSuccess: invalidate });

  if (editing) return <LibraryForm library={library} onDone={() => setEditing(false)} />;
  const folders = library.kind !== "live";

  return (
    <Card>
      <CardHeader
        title={
          <span className="flex flex-wrap items-center gap-2">
            {library.name}
            <Badge>{LIBRARY_KIND_OPTIONS[library.kind].label}</Badge>
          </span>
        }
        description={
          folders ? (
            <ScanStatus library={library} />
          ) : (
            <span>
              No folders: its cameras and web streams are added on{" "}
              <Link to={`/library/${library.id}`} className="text-primary hover:underline">
                its page
              </Link>
              .
            </span>
          )
        }
        actions={
          admin ? (
            <>
              {folders ? (
                <Button variant="secondary" size="sm" onClick={() => scan.mutate()} disabled={library.scanning || scan.isPending}>
                  <RefreshCw className="h-4 w-4" aria-hidden />
                  Scan now
                </Button>
              ) : null}
              <Button variant="ghost" size="sm" onClick={() => setEditing(true)}>
                Edit
              </Button>
              <ConfirmButton
                onConfirm={() => remove.mutate()}
                question="Remove this library? Watch history for its files goes with it; the files are untouched."
              >
                Remove
              </ConfirmButton>
            </>
          ) : null
        }
      />
      {folders ? (
        <CardBody className="space-y-3">
          <ul className="space-y-1">
            {library.roots.map((root) => (
              <li key={root} className="break-all font-mono text-sm text-foreground">
                {root}
              </li>
            ))}
          </ul>
          <div className="flex flex-wrap gap-2">
            {MEDIA_FILE_STATES.filter((state) => state === "probed" || library.file_counts[state] > 0).map((state) => (
              <Badge key={state} tone={MEDIA_FILE_STATE_TONES[state]}>
                {library.file_counts[state]} {MEDIA_FILE_STATE_LABELS[state].toLowerCase()}
              </Badge>
            ))}
          </div>
        </CardBody>
      ) : null}
    </Card>
  );
}

function ScanStatus({ library }: { library: Library }) {
  if (library.scanning) return <span>Scanning now…</span>;
  if (library.last_scan_error) {
    return (
      <span className="text-negative">
        Last scan failed{library.consecutive_scan_failures > 1 ? ` ${library.consecutive_scan_failures} times` : ""}:{" "}
        {library.last_scan_error}
        {library.last_scanned_at ? ` Last good scan ${relativeTime(library.last_scanned_at)}.` : ""}
      </span>
    );
  }
  if (!library.last_scanned_at) return <span>Not scanned yet.</span>;
  return <span>Scanned {relativeTime(library.last_scanned_at)}.</span>;
}

/** Add or edit. Starts from the server's values and does not re-sync on refetch. */
function LibraryForm({ library, onDone }: { library?: Library; onDone: () => void }) {
  const queryClient = useQueryClient();
  const [name, setName] = useState(library?.name ?? "");
  const [kind, setKind] = useState<LibraryKind>(library?.kind ?? "movies");
  const [roots, setRoots] = useState<string[]>(library?.roots.length ? library.roots : [""]);
  const [language, setLanguage] = useState(library?.metadata_language ?? "en");

  const save = useFormMutation({
    mutationFn: () => {
      const body = { library: { name, kind, metadata_language: language, roots: kind === "live" ? [] : roots.filter((root) => root.trim()) } };
      return library ? api.patch<Library>(`/libraries/${library.id}`, body) : api.post<Library>("/libraries", body);
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: keys.libraries.all });
      onDone();
    },
    fallback: "Could not save the library",
  });

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    save.mutate();
  }

  return (
    <Card>
      <CardHeader title={library ? `Edit ${library.name}` : "Add a library"} />
      <CardBody>
        <form onSubmit={onSubmit} className="max-w-xl space-y-4">
          <Input label="Name" value={name} onChange={(event) => setName(event.target.value)} placeholder="Movies" required />
          <Select
            label="Kind"
            value={kind}
            onChange={(event) => setKind(event.target.value as LibraryKind)}
            hint={LIBRARY_KIND_OPTIONS[kind].hint}
            disabled={Boolean(library)}
          >
            {LIBRARY_KINDS.map((value) => (
              <option key={value} value={value}>
                {LIBRARY_KIND_OPTIONS[value].label}
              </option>
            ))}
          </Select>
          {kind !== "live" ? (
            <>
              <fieldset className="space-y-2">
                <legend className="text-sm font-medium text-foreground">Folders</legend>
                {roots.map((root, index) => (
                  <RootField
                    key={index}
                    value={root}
                    onChange={(value) => setRoots((current) => current.map((item, i) => (i === index ? value : item)))}
                    onRemove={
                      roots.length > 1 ? () => setRoots((current) => current.filter((_, i) => i !== index)) : undefined
                    }
                  />
                ))}
                <Button type="button" variant="ghost" size="sm" onClick={() => setRoots((current) => [...current, ""])}>
                  Add another folder
                </Button>
              </fieldset>
              <Input
                label="Metadata language"
                value={language}
                onChange={(event) => setLanguage(event.target.value)}
                hint="Titles and descriptions are fetched in this language, e.g. en or en-GB."
              />
            </>
          ) : null}
          <FormError message={save.errorMessage} />
          <FormFooter label={library ? "Save" : "Add library"} pending={save.isPending} onCancel={onDone} />
        </form>
      </CardBody>
    </Card>
  );
}

/** A folder path, checked against the server when you leave the field. */
function RootField({
  value,
  onChange,
  onRemove,
}: {
  value: string;
  onChange: (value: string) => void;
  onRemove?: () => void;
}) {
  const check = useMutation({
    mutationFn: (path: string) => api.post<PathReport>("/libraries/validate_path", { path }),
    onError: () => undefined,
  });
  const report = check.data?.path === value.trim() ? check.data : undefined;

  return (
    <div className="space-y-1">
      <div className="flex items-start gap-2">
        <Input
          className="font-mono"
          aria-label="Folder path"
          value={value}
          placeholder="/media/movies"
          onChange={(event) => onChange(event.target.value)}
          onBlur={() => (value.trim() ? check.mutate(value.trim()) : undefined)}
        />
        {onRemove ? (
          <IconButton label="Remove this folder" onClick={onRemove}>
            <Trash2 className="h-4 w-4" aria-hidden />
          </IconButton>
        ) : null}
      </div>
      {report ? <TestResultLine ok={report.ok} message={report.message} compact /> : null}
    </div>
  );
}
