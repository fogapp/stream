import { useQuery } from "@tanstack/react-query";
import { useTestConnection } from "@/hooks/useTestConnection";
import { hookQuery } from "@/lib/queries";
import { keys } from "@/lib/queryKeys";
import { ConnectionCard } from "@/components/settings/ConnectionCard";
import { TestResultLine } from "@/components/settings/TestResultLine";
import { CardBody } from "@/components/ui/Card";
import { ErrorState } from "@/components/ui/PageState";

/**
 * Hook (PROPOSAL §7.9): connected by fog, never pasted here. Once it is, the
 * household asks it for films and shows from search; Test says who Hook
 * takes the person asking to be.
 */
export function HookCard() {
  const status = useQuery(hookQuery());
  const test = useTestConnection("/hook/test", keys.hook.all);
  const connected = status.data?.available === true;

  return (
    <ConnectionCard
      title="Hook"
      setUp={connected}
      badge="Connected"
      test={connected ? test : null}
      description={
        connected
          ? "The household asks Hook for films and shows from search: the telescope beside the search field, or ⇧↵. A request is the asker's in Hook when Hook knows their email."
          : "Connect Hook's Library offer on Stream's Integrations tab in fog. fog sets Hook's address and token and redeploys Stream; nothing is pasted here. Then search can ask Hook for films and shows."
      }
    >
      {status.isError ? (
        <CardBody>
          <ErrorState message="Could not load whether Hook is connected." onRetry={() => void status.refetch()} />
        </CardBody>
      ) : test.result ? (
        <CardBody>
          <TestResultLine ok={test.result.ok} message={test.result.message} />
        </CardBody>
      ) : null}
    </ConnectionCard>
  );
}
