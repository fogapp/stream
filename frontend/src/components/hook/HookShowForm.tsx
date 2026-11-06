import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Check, Loader2 } from "lucide-react";
import { api, apiErrorMessage } from "@/api/client";
import { Button } from "@/components/ui/Button";
import { Checkbox } from "@/components/ui/Checkbox";
import { FormError } from "@/components/ui/Form";
import { useFormMutation } from "@/hooks/useFormMutation";
import { askedSummary, askLabel, hookFollow, seasonStanding } from "@/lib/hook";
import { keys } from "@/lib/queryKeys";
import { cn } from "@/lib/cn";
import type { HookHit, HookShow, HookShowAsked } from "@/types";

/**
 * A show found through Hook, opened in the palette (PROPOSAL §7.9): its
 * seasons against what Stream already plays — choose the missing ones —
 * and a follow that keeps new episodes coming. The seasons already aired
 * are asked for by number, so a follow defaults to only what airs from
 * today. Opening it adds the show to Hook's catalog, as Hook's own console
 * does; nothing is wanted until the button is pressed.
 */
export function HookShowForm({ hit, onClose, onOpen }: { hit: HookHit; onClose: () => void; onOpen: () => void }) {
  const queryClient = useQueryClient();
  const showKey = keys.hook.show(hit.provider, hit.external_id);
  const show = useQuery({
    queryKey: showKey,
    queryFn: ({ signal }) => api.post<HookShow>("/hook/shows", { provider: hit.provider, external_id: hit.external_id }, { signal }),
    staleTime: Infinity,
    refetchOnWindowFocus: false,
    retry: false,
  });
  const [chosen, setChosen] = useState<number[]>([]);
  const [follow, setFollow] = useState(false);
  const [futureOnly, setFutureOnly] = useState(true);
  const [done, setDone] = useState<string | null>(null);
  const panel = useRef<HTMLDivElement>(null);

  const ask = useFormMutation({
    mutationFn: (id: string) =>
      api.post<HookShowAsked>(`/hook/shows/${id}/want`, { season_numbers: chosen, follow: hookFollow(follow, futureOnly) }),
    onSuccess: (asked) => {
      queryClient.setQueryData(showKey, asked.show);
      void queryClient.invalidateQueries({ queryKey: [...keys.hook.all, "search"] });
      setDone(askedSummary(asked, follow));
      setChosen([]);
      setFollow(false);
    },
    // Some seasons may have been asked before Hook refused one: show where it stands now.
    onError: () => void queryClient.invalidateQueries({ queryKey: showKey }),
    fallback: "Hook couldn't take the request",
  });

  // Keyboard: open the panel and Tab is already inside it.
  useEffect(() => {
    if (show.data) panel.current?.querySelector<HTMLElement>("button:not(:disabled), input")?.focus();
  }, [show.data]);

  const toggle = (number: number) => {
    setDone(null);
    setChosen((current) => (current.includes(number) ? current.filter((each) => each !== number) : [...current, number]));
  };

  return (
    <div
      ref={panel}
      className="mx-2 mb-2 mt-1 space-y-3 rounded-[var(--radius-control)] border border-border bg-surface-raised p-3"
      onKeyDown={(event) => {
        if (event.key !== "Escape") return;
        event.stopPropagation();
        onClose();
      }}
    >
      {show.isPending ? (
        <p className="flex items-center gap-2 text-sm text-muted">
          <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
          Asking Hook for its seasons…
        </p>
      ) : show.isError ? (
        <div className="flex flex-wrap items-center gap-3">
          <p role="alert" className="text-sm text-negative">
            {apiErrorMessage(show.error, "Hook couldn't open the show.")}
          </p>
          <Button size="sm" variant="secondary" onClick={() => void show.refetch()}>
            Try again
          </Button>
        </div>
      ) : (
        <>
          {show.data.seasons.length > 0 ? (
            <div role="group" aria-label="Seasons to request" className="flex flex-wrap gap-1.5">
              {show.data.seasons.map((season) => {
                const standing = seasonStanding(season);
                const on = chosen.includes(season.number);
                return (
                  <button
                    key={season.number}
                    type="button"
                    aria-pressed={on}
                    disabled={standing.settled}
                    onClick={() => toggle(season.number)}
                    className={cn(
                      "flex min-w-[6.5rem] flex-col items-start rounded-[var(--radius-control)] border px-2.5 py-1.5 text-left transition-colors",
                      on
                        ? "border-primary/50 bg-primary/10"
                        : "border-border bg-surface hover:border-primary/30",
                      "disabled:cursor-default disabled:opacity-60 disabled:hover:border-border",
                    )}
                  >
                    <span className={cn("flex items-center gap-1 text-xs font-medium", on ? "text-primary" : "text-foreground")}>
                      {standing.settled ? <Check className="h-3 w-3 text-positive" aria-hidden /> : null}
                      {standing.label}
                    </span>
                    <span className="text-[11px] text-muted">{standing.hint}</span>
                  </button>
                );
              })}
            </div>
          ) : (
            <p className="text-sm text-muted">Hook knows no seasons of this show yet. Follow it, and new episodes are asked for as they air.</p>
          )}

          {show.data.following ? (
            <p className="flex items-center gap-1.5 text-sm text-muted">
              <Check className="h-4 w-4 text-positive" aria-hidden />
              Following — {show.data.following}
            </p>
          ) : (
            <div className="space-y-1.5">
              <Checkbox
                checked={follow}
                onChange={(checked) => {
                  setDone(null);
                  setFollow(checked);
                }}
                label="Follow the show, so new episodes come as they air"
              />
              {follow ? (
                <Checkbox
                  className="ml-6 text-muted"
                  checked={futureOnly}
                  onChange={setFutureOnly}
                  label="Only episodes from today on"
                />
              ) : null}
            </div>
          )}

          <FormError message={ask.errorMessage} />
          <div className="flex flex-wrap items-center gap-3">
            {chosen.length > 0 || follow ? (
              <Button size="sm" disabled={ask.isPending} onClick={() => ask.mutate(show.data.hook_show_id)}>
                {ask.isPending ? "Asking Hook…" : askLabel([...chosen].sort((a, b) => a - b), follow)}
              </Button>
            ) : done ? (
              <p role="status" className="text-sm text-positive">
                {done}
              </p>
            ) : (
              <p className="text-sm text-muted">Choose the seasons to request.</p>
            )}
            {show.data.in_stream_id ? (
              <Link to={`/show/${show.data.in_stream_id}`} onClick={onOpen} className="ml-auto text-sm text-muted hover:text-foreground">
                Open in Stream
              </Link>
            ) : null}
          </div>
        </>
      )}
    </div>
  );
}
