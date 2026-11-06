import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate, useParams } from "react-router-dom";
import { ArrowLeft, ArrowRight, Lock, Pencil, X } from "lucide-react";
import { api } from "@/api/client";
import { interleave } from "@/lib/collectionShelf";
import { keys } from "@/lib/queryKeys";
import { librariesQuery } from "@/lib/queries";
import { useAuth } from "@/hooks/useAuth";
import { useFormMutation } from "@/hooks/useFormMutation";
import { MissingPosterCard, PosterCard } from "@/components/viewing/cards";
import { Hero } from "@/components/viewing/Hero";
import { PinToHome } from "@/components/viewing/PinToHome";
import { Button } from "@/components/ui/Button";
import { Select } from "@/components/ui/Select";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { FormError, FormFooter } from "@/components/ui/Form";
import { IconButton } from "@/components/ui/IconButton";
import { Input } from "@/components/ui/Input";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import { Textarea } from "@/components/ui/Textarea";
import { SmartRulesForm } from "@/components/viewing/SmartRulesForm";
import type { CollectionDetail as Collection, SmartRules } from "@/types";

const GRID = "grid grid-cols-2 gap-x-3 gap-y-5 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 2xl:grid-cols-8";

/** One collection: its picture and story, then its titles in order. */
export function CollectionDetail() {
  const { id = "" } = useParams();
  const collection = useQuery({ queryKey: keys.collections.detail(id), queryFn: ({ signal }) => api.get<Collection>(`/collections/${id}`, { signal }) });
  return (
    <QueryState query={collection} errorMessage="Could not load this collection.">
      {(data) => <CollectionPage collection={data} />}
    </QueryState>
  );
}

function CollectionPage({ collection }: { collection: Collection }) {
  const { user } = useAuth();
  const admin = user?.role === "admin";
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [editing, setEditing] = useState(false);
  const refresh = () => void queryClient.invalidateQueries({ queryKey: keys.collections.all });

  const remove = useMutation({
    mutationFn: (item: { kind: string; id: string }) =>
      api.delete(`/collections/${collection.id}/items?item_type=${item.kind}&item_id=${item.id}`),
    onSuccess: refresh,
  });
  const reorder = useMutation({
    mutationFn: (ids: string[]) => api.put(`/collections/${collection.id}/order`, { ids }),
    onSuccess: refresh,
  });
  const destroy = useMutation({
    mutationFn: () => api.delete(`/collections/${collection.id}`),
    onSuccess: () => {
      refresh();
      navigate("/collections");
    },
  });

  const manual = collection.collection_kind === "manual";
  // A TMDB series in release order, what nobody has faded in its place.
  const shelf = interleave(collection.items, collection.missing);
  const total = collection.item_count + collection.missing.length;
  const move = (index: number, by: -1 | 1) => {
    const ids = collection.items.map((item) => item.id);
    const [moved] = ids.splice(index, 1);
    if (!moved) return;
    ids.splice(index + by, 0, moved);
    reorder.mutate(ids);
  };

  return (
    <div className="pb-10">
      <Hero images={collection.images} title={collection.title}>
        <p className="text-sm text-muted">
          {collection.missing.length > 0
            ? `${collection.item_count} of ${total} in your library`
            : `${collection.item_count} ${collection.item_count === 1 ? "title" : "titles"}`}{" "}
          ·{" "}
          {collection.collection_kind === "smart" ? "Smart: fills itself by its rules" : manual ? "Your collection" : "From TMDB"}
          {collection.locked_fields.length > 0 ? (
            <span className="ml-2 inline-flex items-center gap-1" title="Edited here; TMDB won't change it">
              <Lock className="h-3 w-3" aria-hidden />
              Edited
            </span>
          ) : null}
        </p>
        {collection.overview ? <p className="max-w-3xl text-sm leading-relaxed text-foreground/90 sm:text-base">{collection.overview}</p> : null}
        <PinToHome kind="collection" id={collection.id} pinned={collection.pinned_to_home} onChange={() => void queryClient.invalidateQueries({ queryKey: keys.collections.all })} />
        {admin && !editing ? (
          <div className="flex flex-wrap gap-2">
            <Button variant="secondary" onClick={() => setEditing(true)}>
              <Pencil className="h-4 w-4" aria-hidden />
              Edit
            </Button>
            {manual || collection.collection_kind === "smart" ? (
              <ConfirmButton size="md" question="Delete this collection? Its titles stay." onConfirm={() => destroy.mutate()}>
                Delete collection
              </ConfirmButton>
            ) : null}
          </div>
        ) : null}
        {editing && collection.rules ? (
          <EditSmart collection={collection} rules={collection.rules} onDone={() => setEditing(false)} />
        ) : editing ? (
          <EditCollection collection={collection} onDone={() => setEditing(false)} />
        ) : null}
      </Hero>
      <div className="px-4 pt-6 sm:px-6 lg:px-8">
        {shelf.length === 0 ? (
          <EmptyState title="Nothing in it yet" description="Add titles from their pages: Add to collection." />
        ) : manual ? (
          <div className={GRID}>
            {collection.items.map((item, index) => (
              <div key={`${item.kind}-${item.id}`} className="group/item relative">
                <PosterCard item={item} />
                {admin && manual ? (
                  <div className="absolute inset-x-1.5 top-1.5 flex justify-between opacity-0 transition focus-within:opacity-100 group-hover/item:opacity-100">
                    <div className="flex gap-1">
                      <IconButton label={`Move ${item.title} earlier`} disabled={index === 0} onClick={() => move(index, -1)} className="rounded-full bg-background/80">
                        <ArrowLeft className="h-3.5 w-3.5" aria-hidden />
                      </IconButton>
                      <IconButton
                        label={`Move ${item.title} later`}
                        disabled={index === collection.items.length - 1}
                        onClick={() => move(index, 1)}
                        className="rounded-full bg-background/80"
                      >
                        <ArrowRight className="h-3.5 w-3.5" aria-hidden />
                      </IconButton>
                    </div>
                    <IconButton label={`Remove ${item.title} from ${collection.title}`} onClick={() => remove.mutate(item)} className="rounded-full bg-background/80">
                      <X className="h-3.5 w-3.5" aria-hidden />
                    </IconButton>
                  </div>
                ) : null}
              </div>
            ))}
          </div>
        ) : (
          <div className={GRID}>
            {shelf.map((entry) =>
              entry.kind === "missing" ? (
                <MissingPosterCard key={`missing-${entry.part.tmdb_id}`} part={entry.part} />
              ) : (
                <PosterCard key={`${entry.item.kind}-${entry.item.id}`} item={entry.item} />
              ),
            )}
          </div>
        )}
      </div>
    </div>
  );
}

function EditCollection({ collection, onDone }: { collection: Collection; onDone: () => void }) {
  const queryClient = useQueryClient();
  const [title, setTitle] = useState(collection.title);
  const [overview, setOverview] = useState(collection.overview ?? "");
  const [libraryId, setLibraryId] = useState(collection.library?.id ?? "");
  const libraries = useQuery(librariesQuery());
  const save = useFormMutation({
    fallback: "Couldn't save the collection.",
    mutationFn: () => api.patch<Collection>(`/collections/${collection.id}`, { title, overview, library_id: libraryId }),
    onSuccess: (updated) => {
      queryClient.setQueryData(keys.collections.detail(collection.id), updated);
      void queryClient.invalidateQueries({ queryKey: keys.collections.all });
      onDone();
    },
  });
  return (
    <form
      className="max-w-xl space-y-3 rounded-[var(--radius-card)] bg-surface/90 p-4 ring-1 ring-border"
      onSubmit={(event) => {
        event.preventDefault();
        save.mutate();
      }}
    >
      <Input label="Title" name="title" value={title} onChange={(event) => setTitle(event.target.value)} required />
      <Textarea label="Overview" name="overview" rows={3} value={overview} onChange={(event) => setOverview(event.target.value)} />
      <Select label="Belongs to" value={libraryId} onChange={(event) => setLibraryId(event.target.value)} hint="A library's collections show with that library; the household's with every library they have titles in.">
        <option value="">The household</option>
        {(libraries.data ?? [])
          .filter((library) => library.kind === "movies" || library.kind === "shows")
          .map((library) => (
            <option key={library.id} value={library.id}>
              {library.name}
            </option>
          ))}
      </Select>
      {collection.collection_kind === "tmdb" ? <p className="text-xs text-muted">What you change here is kept when TMDB's details are refreshed.</p> : null}
      <FormError message={save.errorMessage} />
      <FormFooter label="Save" pending={save.isPending} onCancel={onDone} />
    </form>
  );
}

function EditSmart({ collection, rules, onDone }: { collection: Collection; rules: SmartRules; onDone: () => void }) {
  const queryClient = useQueryClient();
  const save = useFormMutation({
    fallback: "Couldn't save the rules.",
    mutationFn: ({ title, next }: { title: string; next: SmartRules }) => api.patch<Collection>(`/collections/${collection.id}`, { title, rules: next }),
    onSuccess: (updated) => {
      queryClient.setQueryData(keys.collections.detail(collection.id), updated);
      void queryClient.invalidateQueries({ queryKey: keys.collections.all });
      onDone();
    },
  });
  return (
    <SmartRulesForm
      initialTitle={collection.title}
      initialRules={rules}
      pending={save.isPending}
      error={save.errorMessage}
      submitLabel="Save rules"
      onSubmit={(title, next) => save.mutate({ title, next })}
      onCancel={onDone}
    />
  );
}
