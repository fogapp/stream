import { useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ImagePlus, Upload, X } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { Button } from "@/components/ui/Button";
import { FormError } from "@/components/ui/Form";
import { IconButton } from "@/components/ui/IconButton";
import { QueryState } from "@/components/ui/PageState";
import { Segmented } from "@/components/ui/Segmented";
import type { ArtworkChoices } from "@/types";

const KINDS = [
  { key: "poster", label: "Poster" },
  { key: "backdrop", label: "Background" },
] as const;
type Kind = (typeof KINDS)[number]["key"];

/**
 * Choosing a title's poster or background (PROPOSAL §7.2): one of TMDB's
 * others, or an upload. Either is kept through metadata refreshes until
 * reset. Admins only.
 */
export function ArtworkPicker({ ownerType, ownerId }: { ownerType: "movie" | "show"; ownerId: string }) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <Button size="lg" variant="ghost" onClick={() => setOpen(true)}>
        <ImagePlus className="h-4 w-4" aria-hidden />
        Change pictures
      </Button>
      {open ? <ArtworkPickerDialog ownerType={ownerType} ownerId={ownerId} onClose={() => setOpen(false)} /> : null}
    </>
  );
}

/** The picker itself, for a control that isn't this button (a "…" menu's). */
export function ArtworkPickerDialog({ ownerType, ownerId, onClose }: { ownerType: "movie" | "show"; ownerId: string; onClose: () => void }) {
  const queryClient = useQueryClient();
  const [kind, setKind] = useState<Kind>("poster");
  const file = useRef<HTMLInputElement>(null);
  const params = `owner_type=${ownerType}&owner_id=${ownerId}&kind=${kind}`;
  const choices = useQuery({
    queryKey: keys.artworkChoices.list(ownerType, ownerId, kind),
    queryFn: ({ signal }) => api.get<ArtworkChoices>(`/artwork_choices?${params}`, { signal }),
  });
  const done = () =>
    Promise.all([
      queryClient.invalidateQueries({ queryKey: keys.artworkChoices.all }),
      queryClient.invalidateQueries({ queryKey: ownerType === "movie" ? keys.movies.all : keys.shows.all }),
      queryClient.invalidateQueries({ queryKey: keys.home.all }),
    ]);
  const body = { owner_type: ownerType, owner_id: ownerId, kind };
  const choose = useMutation({ mutationFn: (path: string) => api.put("/artwork_choices/choose", { ...body, path }), onSuccess: done, onError: () => undefined });
  const upload = useMutation({
    mutationFn: (picked: File) => {
      const form = new FormData();
      Object.entries(body).forEach(([key, value]) => form.append(key, value));
      form.append("file", picked);
      return api.postForm("/artwork_choices/upload", form);
    },
    onSuccess: done,
    onError: () => undefined,
  });
  const reset = useMutation({ mutationFn: () => api.delete(`/artwork_choices/reset?${params}`), onSuccess: done, onError: () => undefined });
  const error = choose.error ?? upload.error ?? reset.error;
  const busy = choose.isPending || upload.isPending || reset.isPending;

  return (
    <div role="dialog" aria-modal="true" aria-label="Change pictures" className="fixed inset-0 z-50 overflow-y-auto bg-background/95 p-4 sm:p-8">
      <div className="mx-auto max-w-6xl space-y-4">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <Segmented segments={KINDS} value={kind} onChange={(key) => setKind(key as Kind)} label="Picture" />
          <div className="flex items-center gap-2">
            <input
              ref={file}
              type="file"
              accept="image/*"
              className="sr-only"
              aria-label="Upload a picture"
              onChange={(event) => {
                const picked = event.target.files?.[0];
                if (picked) upload.mutate(picked);
                event.target.value = "";
              }}
            />
            <Button size="sm" variant="secondary" onClick={() => file.current?.click()} disabled={busy}>
              <Upload className="h-4 w-4" aria-hidden /> Upload
            </Button>
            {choices.data?.locked ? (
              <Button size="sm" variant="ghost" onClick={() => reset.mutate()} disabled={busy}>
                Use TMDB's again
              </Button>
            ) : null}
            <IconButton label="Close" onClick={onClose}>
              <X className="h-5 w-5" aria-hidden />
            </IconButton>
          </div>
        </div>
        <FormError message={error ? (error as Error).message : null} />
        {busy ? <p className="text-sm text-muted">Rendering…</p> : null}
        <QueryState query={choices} errorMessage="TMDB's pictures didn't load.">
          {(data) =>
            data.choices.length === 0 ? (
              <p className="text-sm text-muted">TMDB has no other pictures for this. Upload one instead.</p>
            ) : (
              <ul className={kind === "poster" ? "grid grid-cols-3 gap-3 sm:grid-cols-5 lg:grid-cols-7" : "grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3"}>
                {data.choices.map((choice) => {
                  const current = data.current?.path === choice.path;
                  return (
                    <li key={choice.path}>
                      <button
                        type="button"
                        onClick={() => choose.mutate(choice.path)}
                        disabled={busy || current}
                        aria-pressed={current}
                        aria-label={`Use this ${kind === "poster" ? "poster" : "background"}${choice.language ? ` (${choice.language})` : ""}`}
                        className={
                          current
                            ? "block w-full overflow-hidden rounded-[var(--radius-card)] ring-4 ring-primary"
                            : "block w-full overflow-hidden rounded-[var(--radius-card)] ring-1 ring-border hover:ring-primary"
                        }
                      >
                        <img src={choice.preview} alt="" loading="lazy" className={kind === "poster" ? "aspect-[2/3] w-full object-cover" : "aspect-video w-full object-cover"} />
                      </button>
                    </li>
                  );
                })}
              </ul>
            )
          }
        </QueryState>
      </div>
    </div>
  );
}
