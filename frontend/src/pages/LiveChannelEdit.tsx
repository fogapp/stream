import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate, useParams } from "react-router-dom";
import { Trash2 } from "lucide-react";
import { api, apiErrorMessage } from "@/api/client";
import { PageHeader } from "@/components/layout/PageHeader";
import { PresetPicker } from "@/components/live/PresetPicker";
import { StationEditor } from "@/components/live/StationEditor";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { FormError } from "@/components/ui/Form";
import { ErrorState, LoadingState } from "@/components/ui/PageState";
import { useFormMutation } from "@/hooks/useFormMutation";
import { keys } from "@/lib/queryKeys";
import { draftFrom, draftFromPreset, type StationDraft } from "@/lib/stationDraft";
import type { PresetKind, StationConfig, StationOptions, StationPresetDraft } from "@/types";

/**
 * Making or editing one Grid channel (PROPOSAL §7.7). A new one starts
 * from a preset or from scratch; either way the editor opens with it.
 */
export function LiveChannelEdit() {
  const { id = "new" } = useParams();
  const creating = id === "new";
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [start, setStart] = useState<{ draft: StationDraft; description: string | null } | null>(null);
  const [presetError, setPresetError] = useState<string | null>(null);
  const [loadingPreset, setLoadingPreset] = useState(false);
  const options = useQuery({ queryKey: keys.live.options(), queryFn: ({ signal }) => api.get<StationOptions>("/stations/options", { signal }) });
  const station = useQuery({
    queryKey: keys.live.station(id),
    queryFn: ({ signal }) => api.get<StationConfig>(`/stations/${id}`, { signal }),
    enabled: !creating,
  });
  const save = useFormMutation({
    fallback: "Couldn't save the channel.",
    mutationFn: (draft: StationDraft) =>
      creating ? api.post<StationConfig>("/stations", draft) : api.patch<StationConfig>(`/stations/${id}`, draft),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: keys.live.all });
      navigate("/live/channels");
    },
  });
  const remove = useFormMutation({
    fallback: "Couldn't delete the channel.",
    mutationFn: () => api.delete(`/stations/${id}`),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: keys.live.all });
      navigate("/live/channels");
    },
  });

  const pick = (kind: PresetKind, value?: string) => {
    setLoadingPreset(true);
    setPresetError(null);
    queryClient
      .fetchQuery({
        queryKey: keys.live.preset(kind, value ?? ""),
        queryFn: ({ signal }) => api.get<StationPresetDraft>(`/stations/preset?kind=${kind}${value ? `&value=${encodeURIComponent(value)}` : ""}`, { signal }),
      })
      .then((preset) => setStart({ draft: draftFromPreset(preset), description: preset.description }))
      .catch((failure: unknown) => setPresetError(apiErrorMessage(failure, "Couldn't make that channel.")))
      .finally(() => setLoadingPreset(false));
  };

  const loading = options.isPending || (!creating && station.isPending);
  const failed = options.isError || (!creating && station.isError);
  const editing = !creating || start !== null;

  return (
    <div className="space-y-6 px-4 py-6 sm:px-6 lg:px-8">
      <PageHeader
        title={creating ? (start ? `New channel: ${start.draft.name}` : "New channel") : station.data ? `${station.data.number} ${station.data.name}` : "Channel"}
        description={creating ? (start?.description ?? "Start from a ready-made channel, built from what's in the library — or from scratch.") : (station.data?.last_error ?? undefined)}
        actions={
          creating ? null : (
            <ConfirmButton question="Delete this channel and its schedule?" onConfirm={() => remove.mutate()} disabled={remove.isPending}>
              <Trash2 className="h-4 w-4" aria-hidden />
              Delete
            </ConfirmButton>
          )
        }
      />
      {failed ? (
        <ErrorState message="The channel couldn't be loaded." onRetry={() => void Promise.all([options.refetch(), station.refetch()])} />
      ) : loading || !options.data ? (
        <LoadingState />
      ) : !editing ? (
        <>
          <FormError message={presetError} />
          <PresetPicker
            options={options.data}
            pending={loadingPreset}
            onPick={pick}
            onScratch={() => setStart({ draft: draftFrom(null), description: null })}
          />
        </>
      ) : (
        <StationEditor
          key={start ? start.draft.name : id}
          stationId={creating ? null : id}
          initial={start?.draft ?? draftFrom(station.data ?? null)}
          options={options.data}
          pending={save.isPending}
          error={save.errorMessage ?? remove.errorMessage}
          submitLabel={creating ? "Make channel" : "Save and rebuild schedule"}
          onSubmit={(draft) => save.mutate(draft)}
          onCancel={() => (creating ? setStart(null) : navigate("/live/channels"))}
        />
      )}
    </div>
  );
}
