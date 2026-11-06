import { useEffect, type ReactNode } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ExternalLink } from "lucide-react";
import { api } from "@/api/client";
import { useFormMutation } from "@/hooks/useFormMutation";
import { keys } from "@/lib/queryKeys";
import { relativeTime } from "@/lib/time";
import { Badge, type BadgeTone } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { FormError } from "@/components/ui/Form";
import { QueryState } from "@/components/ui/PageState";
import type { TraktAccountInfo, TraktLink, TraktLinkState } from "@/types";

const STATE_LABELS: Record<TraktLinkState, string> = { pending: "Linking", linked: "Linked", needs_relink: "Link again" };
const STATE_TONES: Record<TraktLinkState, BadgeTone> = { pending: "info", linked: "success", needs_relink: "danger" };

/** Settings › Viewing › Trakt: this profile's own Trakt account (PROPOSAL §7.4), linked with a device code. */
export function TraktLinkCard() {
  const queryClient = useQueryClient();
  const info = useQuery({ queryKey: keys.trakt.account(), queryFn: ({ signal }) => api.get<TraktAccountInfo>("/trakt_account", { signal }) });
  const put = (data: TraktAccountInfo) => queryClient.setQueryData(keys.trakt.account(), data);
  const start = useFormMutation({ mutationFn: () => api.post<TraktAccountInfo>("/trakt_account"), onSuccess: put, fallback: "Couldn't get a code from Trakt." });
  const unlink = useMutation({ mutationFn: () => api.delete<TraktAccountInfo>("/trakt_account"), onSuccess: put });
  const sync = useMutation({ mutationFn: () => api.post<TraktAccountInfo>("/trakt_account/sync"), onSuccess: put });
  const account = info.data?.account ?? null;
  const card = (children: ReactNode) => (
    <Card>
      <CardHeader
        title={
          <span className="flex items-center gap-2">
            Trakt
            {account ? <Badge tone={STATE_TONES[account.state]}>{STATE_LABELS[account.state]}</Badge> : null}
          </span>
        }
        description="What this profile watches is scrobbled to its Trakt account, and history, ratings and watchlist stay in step both ways."
      />
      <CardBody className="space-y-4">{children}</CardBody>
    </Card>
  );

  return card(
    <QueryState query={info} errorMessage="Could not load Trakt.">
      {(data) =>
        !data.available ? (
          <p className="text-sm text-muted">Trakt isn't set up yet — an admin adds it in Settings › Integrations.</p>
        ) : account?.state === "linked" ? (
          <Linked
            account={account}
            onUnlink={() => unlink.mutate()}
            unlinking={unlink.isPending}
            onSync={() => sync.mutate()}
            syncQueued={sync.isSuccess}
          />
        ) : account?.state === "pending" && !expired(account) ? (
          <Pending account={account} onCancel={() => unlink.mutate()} />
        ) : (
          <div className="space-y-3">
            {account?.state === "needs_relink" ? (
              <p className="text-sm text-negative">{account.last_error ?? "Trakt stopped accepting this profile's link."}</p>
            ) : account?.state === "pending" ? (
              <p className="text-sm text-muted">{account.last_error ?? "That code ran out before it was entered."}</p>
            ) : null}
            <Button onClick={() => start.mutate()} disabled={start.isPending}>
              {account ? "Get a new code" : "Link Trakt"}
            </Button>
            <FormError message={start.errorMessage} />
          </div>
        )
      }
    </QueryState>,
  );
}

function expired(account: TraktLink) {
  return !account.code_expires_at || new Date(account.code_expires_at).getTime() <= Date.now();
}

function Pending({ account, onCancel }: { account: TraktLink; onCancel: () => void }) {
  const queryClient = useQueryClient();
  // Asked as often as Trakt allows while the code is on screen.
  useEffect(() => {
    const timer = window.setInterval(
      () => {
        void api
          .post<TraktAccountInfo>("/trakt_account/poll")
          .then((data) => queryClient.setQueryData(keys.trakt.account(), data))
          .catch(() => undefined);
      },
      Math.max(account.poll_interval ?? 5, 5) * 1000,
    );
    return () => window.clearInterval(timer);
  }, [account.poll_interval, queryClient]);

  return (
    <div className="space-y-3">
      <p className="text-sm text-muted">
        Go to{" "}
        <a className="inline-flex items-center gap-1 text-primary hover:underline" href={account.verification_url ?? "https://trakt.tv/activate"} target="_blank" rel="noreferrer">
          {(account.verification_url ?? "https://trakt.tv/activate").replace(/^https?:\/\//, "")}
          <ExternalLink className="h-3 w-3" aria-hidden />
        </a>{" "}
        on any device and enter this code:
      </p>
      <p className="font-mono text-3xl font-semibold tracking-widest text-foreground" aria-live="polite">
        {account.user_code}
      </p>
      <p className="text-xs text-muted">This page carries on once Trakt says yes.</p>
      <Button variant="ghost" size="sm" onClick={onCancel}>
        Cancel
      </Button>
    </div>
  );
}

function Linked({
  account,
  onUnlink,
  unlinking,
  onSync,
  syncQueued,
}: {
  account: TraktLink;
  onUnlink: () => void;
  unlinking: boolean;
  onSync: () => void;
  syncQueued: boolean;
}) {
  return (
    <div className="space-y-3">
      <p className="text-sm text-foreground">
        Linked{account.username ? <> as <span className="font-medium">{account.username}</span></> : null}
        {account.linked_at ? <span className="text-muted"> · {relativeTime(account.linked_at)}</span> : null}
      </p>
      <p className="text-sm text-muted">{account.last_synced_at ? `Last synced ${relativeTime(account.last_synced_at)}.` : "Not synced yet."}</p>
      {account.last_error ? <p className="text-sm text-negative">{account.last_error}</p> : null}
      <div className="flex flex-wrap items-center gap-2">
        <Button variant="secondary" size="sm" onClick={onSync} disabled={syncQueued}>
          {syncQueued ? "Sync queued" : "Sync now"}
        </Button>
        <ConfirmButton variant="secondary" size="sm" onConfirm={onUnlink} disabled={unlinking} question="Unlink Trakt from this profile?">
          Unlink Trakt
        </ConfirmButton>
      </div>
    </div>
  );
}
