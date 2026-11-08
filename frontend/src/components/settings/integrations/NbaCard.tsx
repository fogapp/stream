import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "@/api/client";
import { useConnectionSettings } from "@/hooks/useConnectionSettings";
import { useFormMutation } from "@/hooks/useFormMutation";
import { keys } from "@/lib/queryKeys";
import { ConnectionCard } from "@/components/settings/ConnectionCard";
import { ConnectionTestLine } from "@/components/settings/TestResultLine";
import { Button } from "@/components/ui/Button";
import { CardBody } from "@/components/ui/Card";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { FormError } from "@/components/ui/Form";
import { QueryState } from "@/components/ui/PageState";
import type { NbaSettings } from "@/types";

/**
 * NBA League Pass (PROPOSAL §7.8): turning it on puts Basketball in the
 * sidebar. League Pass games are DRM-protected, so Stream can't play them
 * and keeps no NBA account: a game opens on NBA.com, where you sign in.
 */
export function NbaCard() {
  const queryClient = useQueryClient();
  const { settings, test, current, saved } = useConnectionSettings<NbaSettings>("/nba_setting", keys.nba);
  const changed = (data: NbaSettings) => {
    saved(data);
    void queryClient.invalidateQueries({ queryKey: keys.basketball.all });
  };
  const turnOn = useFormMutation({
    mutationFn: () => api.patch<NbaSettings>("/nba_setting", { nba_setting: {} }),
    onSuccess: changed,
    fallback: "Could not turn on NBA League Pass",
  });
  const turnOff = useMutation({ mutationFn: () => api.delete<NbaSettings>("/nba_setting"), onSuccess: changed });

  return (
    <ConnectionCard
      title="NBA League Pass"
      setUp={current !== null}
      test={current ? test : null}
      description="Turn on, and Basketball in the sidebar shows every game with its score. League Pass games are copy-protected, so they play on NBA.com, where you sign in; Stream keeps no NBA password."
      actions={
        current ? (
          <ConfirmButton onConfirm={() => turnOff.mutate()} question="Turn off NBA League Pass? Basketball leaves the sidebar.">
            Turn off
          </ConfirmButton>
        ) : null
      }
    >
      <CardBody className="space-y-4">
        <QueryState query={settings} errorMessage="Could not load NBA League Pass.">
          {() =>
            current ? (
              <ConnectionTestLine test={test} stored={current} />
            ) : (
              <div className="space-y-3">
                <FormError message={turnOn.errorMessage} />
                <Button size="sm" onClick={() => turnOn.mutate()} disabled={turnOn.isPending}>
                  {turnOn.isPending ? "Turning on…" : "Turn on"}
                </Button>
              </div>
            )
          }
        </QueryState>
      </CardBody>
    </ConnectionCard>
  );
}
