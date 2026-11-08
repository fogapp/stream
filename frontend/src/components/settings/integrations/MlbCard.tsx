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
import type { MlbSettings } from "@/types";

/** MLB.tv: the account yt-dlp signs in with to play a game (PROPOSAL §7.8). Saving one puts Baseball in the sidebar. The password is write-only. */
export function MlbCard() {
  const queryClient = useQueryClient();
  const { settings, test, current, saved } = useConnectionSettings<MlbSettings>("/mlb_setting", keys.mlb);
  const draft = useDraft(current, { username: "", password: "" });
  // Baseball's place in the sidebar follows the account.
  const changed = (data: MlbSettings) => {
    draft.reset();
    saved(data);
    void queryClient.invalidateQueries({ queryKey: keys.baseball.all });
  };
  const save = useFormMutation({
    mutationFn: () => api.patch<MlbSettings>("/mlb_setting", { mlb_setting: draft.values() }),
    onSuccess: changed,
    fallback: "Could not save the MLB.tv account",
  });
  const remove = useMutation({ mutationFn: () => api.delete<MlbSettings>("/mlb_setting"), onSuccess: changed });

  return (
    <ConnectionCard
      title="MLB.tv"
      setUp={current !== null}
      test={current ? test : null}
      description="Sign in, and Baseball in the sidebar shows every game and plays it. Blackouts in this server's area still apply."
      actions={
        current ? (
          <ConfirmButton onConfirm={() => remove.mutate()} question="Forget the MLB.tv account? Baseball leaves the sidebar and games stop playing until it's set again.">
            Forget
          </ConfirmButton>
        ) : null
      }
    >
      <CardBody className="space-y-4">
        <QueryState query={settings} errorMessage="Could not load the MLB.tv account.">
          {() => (
            <>
              {current ? <ConnectionTestLine test={test} stored={current} /> : null}
              <MutationForm mutation={save} label="Save" disabled={!current && !draft.value("password")}>
                <div className="grid gap-4 sm:grid-cols-2">
                  <Input
                    label="Email"
                    type="email"
                    autoComplete="off"
                    value={draft.value("username")}
                    onChange={(event) => draft.set("username", event.target.value)}
                  />
                  <SecretInput
                    label="Password"
                    value={draft.value("password")}
                    onChange={(event) => draft.set("password", event.target.value)}
                    saved={current !== null}
                  />
                </div>
              </MutationForm>
            </>
          )}
        </QueryState>
      </CardBody>
    </ConnectionCard>
  );
}
