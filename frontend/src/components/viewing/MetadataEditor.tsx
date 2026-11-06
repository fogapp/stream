import { useState } from "react";
import { useMutation } from "@tanstack/react-query";
import { Lock, RefreshCw } from "lucide-react";
import { api } from "@/api/client";
import { useFormMutation } from "@/hooks/useFormMutation";
import { Button } from "@/components/ui/Button";
import { FormError, FormFooter } from "@/components/ui/Form";
import { IconButton } from "@/components/ui/IconButton";
import { Input } from "@/components/ui/Input";
import { Textarea } from "@/components/ui/Textarea";
import { cn } from "@/lib/cn";

export interface MetadataField {
  name: string;
  label: string;
  type: "text" | "textarea" | "number" | "date" | "list";
}

export const MOVIE_FIELDS: MetadataField[] = [
  { name: "title", label: "Title", type: "text" },
  { name: "original_title", label: "Original title", type: "text" },
  { name: "year", label: "Year", type: "number" },
  { name: "release_date", label: "Release date", type: "date" },
  { name: "content_rating", label: "Rating", type: "text" },
  { name: "genres", label: "Genres", type: "list" },
  { name: "tagline", label: "Tagline", type: "text" },
  { name: "overview", label: "Overview", type: "textarea" },
];

export const SHOW_FIELDS: MetadataField[] = [
  { name: "title", label: "Title", type: "text" },
  { name: "original_title", label: "Original title", type: "text" },
  { name: "year", label: "Year", type: "number" },
  { name: "content_rating", label: "Rating", type: "text" },
  { name: "network", label: "Network", type: "text" },
  { name: "status", label: "Status", type: "text" },
  { name: "genres", label: "Genres", type: "list" },
  { name: "overview", label: "Overview", type: "textarea" },
];

export const EPISODE_FIELDS: MetadataField[] = [
  { name: "title", label: "Title", type: "text" },
  { name: "air_date", label: "Air date", type: "date" },
  { name: "overview", label: "Overview", type: "textarea" },
];

function asText(value: unknown): string {
  if (Array.isArray(value)) return value.join(", ");
  return value === null || value === undefined ? "" : String(value);
}

/**
 * Correcting a title's details (PROPOSAL §4.2). Whatever is changed is
 * locked, so TMDB never writes it again; the padlock hands a field back.
 */
export function MetadataEditor({
  kind,
  id,
  fields,
  values,
  locked,
  onSaved,
  onUnlocked,
  onCancel,
}: {
  kind: "movie" | "show" | "episode";
  id: string;
  fields: MetadataField[];
  values: Record<string, unknown>;
  locked: string[];
  onSaved: () => void;
  /** A field handed back to TMDB: refresh what's shown, keep editing. */
  onUnlocked: () => void;
  onCancel: () => void;
}) {
  const [draft, setDraft] = useState(() => Object.fromEntries(fields.map((field) => [field.name, asText(values[field.name])])));
  const save = useFormMutation({
    fallback: "Couldn't save these details.",
    mutationFn: () => {
      const changes = Object.fromEntries(fields.filter((field) => draft[field.name] !== asText(values[field.name])).map((field) => [field.name, draft[field.name]]));
      return api.patch(`/metadata/${kind}/${id}`, { changes });
    },
    onSuccess: onSaved,
  });
  const unlock = useMutation({
    mutationFn: (field: string) => api.patch(`/metadata/${kind}/${id}`, { unlock: [field] }),
    onSuccess: onUnlocked,
  });
  const refresh = useMutation({ mutationFn: () => api.post(`/metadata/${kind}/${id}/refresh`) });

  return (
    <form
      className="space-y-4 rounded-[var(--radius-card)] border border-border bg-surface p-4"
      onSubmit={(event) => {
        event.preventDefault();
        save.mutate();
      }}
    >
      <div className="grid gap-4 sm:grid-cols-2">
        {fields.map((field) => {
          const isLocked = locked.includes(field.name);
          const common = {
            name: `${kind}-${field.name}`,
            value: draft[field.name] ?? "",
            onChange: (event: { target: { value: string } }) => setDraft((current) => ({ ...current, [field.name]: event.target.value })),
          };
          return (
            <div key={field.name} className={cn("relative", field.type === "textarea" && "sm:col-span-2")}>
              {field.type === "textarea" ? (
                <Textarea label={field.label} rows={4} {...common} />
              ) : (
                <Input
                  label={field.label}
                  type={field.type === "number" ? "number" : field.type === "date" ? "date" : "text"}
                  hint={field.type === "list" ? "Separated by commas" : undefined}
                  {...common}
                />
              )}
              {isLocked ? (
                <IconButton
                  label={`Unlock ${field.label.toLowerCase()} (let TMDB set it again)`}
                  title="Edited here, so TMDB leaves it alone. Unlock to let TMDB set it again."
                  onClick={() => unlock.mutate(field.name)}
                  className="absolute right-0 top-0 h-5 w-5 text-primary"
                >
                  <Lock className="h-3.5 w-3.5" aria-hidden />
                </IconButton>
              ) : null}
            </div>
          );
        })}
      </div>
      <p className="text-xs text-muted">Fields you change are locked, so a refresh from TMDB keeps them. The padlock unlocks one.</p>
      <FormError message={save.errorMessage} />
      <div className="flex flex-wrap items-center justify-between gap-2">
        <FormFooter label="Save" pending={save.isPending} onCancel={onCancel} />
        <Button type="button" variant="ghost" size="sm" disabled={refresh.isPending || refresh.isSuccess} onClick={() => refresh.mutate()}>
          <RefreshCw className="h-4 w-4" aria-hidden />
          {refresh.isSuccess ? "Refreshing…" : "Refresh from TMDB"}
        </Button>
      </div>
    </form>
  );
}
