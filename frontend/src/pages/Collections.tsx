import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { Segmented } from "@/components/ui/Segmented";
import { Library as LibraryIcon, Sparkles } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { librariesQuery } from "@/lib/queries";
import { useAuth } from "@/hooks/useAuth";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { PageHeader } from "@/components/layout/PageHeader";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import { useFormMutation } from "@/hooks/useFormMutation";
import { Button } from "@/components/ui/Button";
import { EMPTY_RULES, SmartRulesForm } from "@/components/viewing/SmartRulesForm";
import type { CollectionCard, SmartRules } from "@/types";

const GRID = "grid grid-cols-2 gap-x-3 gap-y-5 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 2xl:grid-cols-8";

/** Every collection (PROPOSAL §4.2): TMDB's series and the household's own shelves. */
export function Collections() {
  const [params, setParams] = useSearchParams();
  const libraryId = params.get("library") ?? undefined;
  const libraries = useQuery(librariesQuery());
  const choices = (libraries.data ?? []).filter((library) => library.kind === "movies" || library.kind === "shows");
  const collections = useQuery({
    queryKey: keys.collections.list(libraryId),
    queryFn: ({ signal }) => api.get<CollectionCard[]>(`/collections${libraryId ? `?library_id=${libraryId}` : ""}`, { signal }),
  });
  const { user } = useAuth();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [making, setMaking] = useState(false);
  const create = useFormMutation({
    fallback: "Couldn't make the collection.",
    mutationFn: ({ title, rules }: { title: string; rules: SmartRules }) => api.post<{ id: string }>("/collections", { kind: "smart", title, rules }),
    onSuccess: (created) => {
      void queryClient.invalidateQueries({ queryKey: keys.collections.all });
      navigate(`/collection/${created.id}`);
    },
  });

  return (
    <div className="space-y-6 px-4 py-6 sm:px-6 lg:px-8 lg:py-8">
      <PageHeader
        title="Collections"
        description="Film series from TMDB, shelves of your own, and smart ones that fill themselves."
        actions={
          user?.role === "admin" && !making ? (
            <Button onClick={() => setMaking(true)}>
              <Sparkles className="h-4 w-4" aria-hidden />
              New smart collection
            </Button>
          ) : null
        }
      />
      {choices.length > 1 ? (
        <Segmented
          segments={[{ key: "all", label: "All" }, ...choices.map((library) => ({ key: library.id, label: library.name }))]}
          value={libraryId ?? "all"}
          onChange={(key) => setParams(key === "all" ? {} : { library: key }, { replace: true })}
          label="Library"
        />
      ) : null}
      {making ? (
        <SmartRulesForm
          initialTitle=""
          initialRules={EMPTY_RULES}
          pending={create.isPending}
          error={create.errorMessage}
          submitLabel="Make it"
          onSubmit={(title, rules) => create.mutate({ title, rules })}
          onCancel={() => setMaking(false)}
        />
      ) : null}
      <QueryState query={collections} errorMessage="Could not load collections.">
        {(list) =>
          list.length === 0 ? (
            <EmptyState
              title="No collections yet"
              description={
                user?.role === "admin"
                  ? "Films that belong to a series gather here once they're matched. Make your own from any title's page."
                  : "Films that belong to a series gather here once they're matched."
              }
            />
          ) : (
            <div className={GRID}>
              {list.map((collection) => (
                <CollectionPoster key={collection.id} collection={collection} />
              ))}
            </div>
          )
        }
      </QueryState>
    </div>
  );
}

function CollectionPoster({ collection }: { collection: CollectionCard }) {
  return (
    <Link to={`/collection/${collection.id}`} className="group block min-w-0">
      <ArtworkImage
        image={collection.images.poster}
        sizes="(min-width: 1280px) 12rem, (min-width: 768px) 10rem, 40vw"
        className="aspect-[2/3] rounded-[var(--radius-card)] ring-1 ring-border transition group-hover:ring-2 group-hover:ring-primary"
        fallback={<LibraryIcon className="h-8 w-8 text-muted" aria-hidden />}
      />
      <p className="mt-2 truncate text-sm font-medium text-foreground">{collection.title}</p>
      <p className="text-xs text-muted">
        {collection.item_count} {collection.item_count === 1 ? "title" : "titles"}
      </p>
    </Link>
  );
}
