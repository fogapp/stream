import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "@/api/client";
import { useConnectionSettings } from "@/hooks/useConnectionSettings";
import { useDraft } from "@/hooks/useDraft";
import { useFormMutation } from "@/hooks/useFormMutation";
import { keys } from "@/lib/queryKeys";
import { ConnectionCard } from "@/components/settings/ConnectionCard";
import { ConnectionTestLine } from "@/components/settings/TestResultLine";
import { CardBody } from "@/components/ui/Card";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { Input } from "@/components/ui/Input";
import { MutationForm } from "@/components/ui/MutationForm";
import { QueryState } from "@/components/ui/PageState";
import { SecretInput } from "@/components/ui/SecretInput";
import type { TraktSettings } from "@/types";

/** Trakt: the household's registered Trakt API app, through which each adult profile links its own account (PROPOSAL §7.4). */
export function TraktCard() {
  const queryClient = useQueryClient();
  const { settings, test, current, saved } = useConnectionSettings<TraktSettings>("/trakt_setting", keys.trakt);
  const draft = useDraft(current, { client_id: "", client_secret: "" });
  const save = useFormMutation({
    mutationFn: () => api.patch<TraktSettings>("/trakt_setting", { trakt_setting: draft.values() }),
    onSuccess: (data) => {
      draft.reset();
      saved(data);
    },
    fallback: "Could not save Trakt's settings",
  });
  const remove = useMutation({
    mutationFn: () => api.delete<TraktSettings>("/trakt_setting"),
    onSuccess: (data) => {
      saved(data);
      void queryClient.invalidateQueries({ queryKey: keys.trakt.account() });
    },
  });

  return (
    <ConnectionCard
      title="Trakt"
      setUp={current !== null}
      test={current ? test : null}
      description="Register an app at trakt.tv/oauth/applications (redirect URI urn:ietf:wg:oauth:2.0:oob), then each adult profile links its own account in Settings › Viewing."
    >
      <CardBody className="space-y-4">
        {current ? <ConnectionTestLine test={test} stored={current} /> : null}
        <QueryState query={settings} errorMessage="Could not load Trakt's settings.">
          {() => (
            <MutationForm mutation={save} label="Save" disabled={!current && (!draft.value("client_secret").trim() || !draft.value("client_id").trim())}>
              <Input label="Client ID" autoComplete="off" value={draft.value("client_id")} onChange={(event) => draft.set("client_id", event.target.value)} />
              <SecretInput
                label="Client secret"
                value={draft.value("client_secret")}
                onChange={(event) => draft.set("client_secret", event.target.value)}
                saved={current !== null}
              />
            </MutationForm>
          )}
        </QueryState>
        {current ? (
          <ConfirmButton onConfirm={() => remove.mutate()} disabled={remove.isPending} question="Remove Trakt and unlink every profile?">
            Remove Trakt
          </ConfirmButton>
        ) : null}
      </CardBody>
    </ConnectionCard>
  );
}
