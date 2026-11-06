import type { ReactNode } from "react";
import { TestButton } from "@/components/settings/TestButton";
import { ConnectionBadge } from "@/components/settings/TestResultLine";
import { Card, CardHeader } from "@/components/ui/Card";
import type { TestConnection } from "@/hooks/useTestConnection";

/**
 * A connection's card in Settings: its name and whether it's set up, what it
 * does, and its Test (once there's something to test) with any other actions.
 */
export function ConnectionCard({
  title,
  setUp,
  enabled,
  badge,
  description,
  test,
  actions,
  children,
}: {
  title: string;
  setUp: boolean;
  enabled?: boolean;
  /** The badge's word when it's set up. */
  badge?: string;
  description: ReactNode;
  /** Offered only once it's set up. */
  test?: TestConnection | null;
  actions?: ReactNode;
  children?: ReactNode;
}) {
  return (
    <Card>
      <CardHeader
        title={
          <span className="flex items-center gap-2">
            {title}
            <ConnectionBadge setUp={setUp} enabled={enabled} label={badge} />
          </span>
        }
        description={description}
        actions={
          test || actions ? (
            <>
              {test ? <TestButton connection={test} /> : null}
              {actions}
            </>
          ) : null
        }
      />
      {children}
    </Card>
  );
}
