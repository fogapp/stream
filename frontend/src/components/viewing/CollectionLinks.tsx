import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { Library as LibraryIcon, Plus } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { useAuth } from "@/hooks/useAuth";
import { Button } from "@/components/ui/Button";
import { Checkbox } from "@/components/ui/Checkbox";
import { Input } from "@/components/ui/Input";
import { Menu } from "@/components/ui/Menu";
import type { CollectionCard, CollectionRef } from "@/types";

/** "Part of the Alien Collection", on a title's page. */
export function PartOf({ collections }: { collections: CollectionRef[] }) {
  if (collections.length === 0) return null;
  return (
    <p className="flex flex-wrap items-center gap-x-2 text-sm text-muted">
      <LibraryIcon className="h-4 w-4" aria-hidden />
      Part of
      {collections.map((collection, index) => (
        <span key={collection.id}>
          <Link to={`/collection/${collection.id}`} className="text-foreground underline-offset-4 hover:underline">
            {collection.title}
          </Link>
          {index < collections.length - 1 ? "," : ""}
        </span>
      ))}
    </p>
  );
}

/** An admin's shelf-picker on a title's page: tick your collections, or start one. */
export function AddToCollection({ item, member, onChange }: { item: { kind: "movie" | "show"; id: string }; member: CollectionRef[]; onChange: () => void }) {
  const { user } = useAuth();
  const queryClient = useQueryClient();
  const [title, setTitle] = useState("");
  const collections = useQuery({
    queryKey: keys.collections.list(),
    queryFn: ({ signal }) => api.get<CollectionCard[]>("/collections", { signal }),
    enabled: user?.role === "admin",
  });
  const done = () => {
    void queryClient.invalidateQueries({ queryKey: keys.collections.all });
    onChange();
  };
  const toggle = useMutation({
    mutationFn: ({ id, add }: { id: string; add: boolean }) =>
      add
        ? api.post(`/collections/${id}/items`, { item_type: item.kind, item_id: item.id })
        : api.delete(`/collections/${id}/items?item_type=${item.kind}&item_id=${item.id}`),
    onSuccess: done,
  });
  const create = useMutation({
    mutationFn: () => api.post("/collections", { title: title.trim(), item_type: item.kind, item_id: item.id }),
    onSuccess: () => {
      setTitle("");
      done();
    },
  });
  if (user?.role !== "admin") return null;

  const own = (collections.data ?? []).filter((collection) => collection.collection_kind === "manual");
  const inIt = new Set(member.map((collection) => collection.id));
  return (
    <Menu label="Add to collection" align="left" icon={<Plus className="h-4 w-4" aria-hidden />} className="self-center">
      <div className="space-y-3">
        {own.length > 0 ? (
          <div className="max-h-56 space-y-2 overflow-y-auto">
            {own.map((collection) => (
              <Checkbox
                key={collection.id}
                label={collection.title}
                checked={inIt.has(collection.id)}
                disabled={toggle.isPending}
                onChange={(add) => toggle.mutate({ id: collection.id, add })}
              />
            ))}
          </div>
        ) : null}
        <form
          className="flex gap-2"
          onSubmit={(event) => {
            event.preventDefault();
            if (title.trim()) create.mutate();
          }}
        >
          <Input aria-label="New collection" placeholder="New collection…" value={title} onChange={(event) => setTitle(event.target.value)} />
          <Button type="submit" size="sm" disabled={!title.trim() || create.isPending}>
            Add
          </Button>
        </form>
      </div>
    </Menu>
  );
}
