import { useState, type FormEvent } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Plus } from "lucide-react";
import { api } from "@/api/client";
import { useFormMutation } from "@/hooks/useFormMutation";
import { keys } from "@/lib/queryKeys";
import { relativeTime } from "@/lib/time";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { FormError, FormFooter } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import { SectionHeader } from "@/components/ui/SectionHeader";
import type { ApiToken, ApiTokenCreated } from "@/types";
import { RevealedSecret } from "@/components/ui/RevealedSecret";

/**
 * Long-lived credentials for scripts and integrations — a yt-dlp
 * post-processor, a home-automation hub. The plaintext is shown exactly once,
 * on creation; afterwards only its prefix identifies it.
 */
export function ApiTokens() {
  const [adding, setAdding] = useState(false);
  const [revealed, setRevealed] = useState<ApiTokenCreated | null>(null);
  const list = useQuery({
    queryKey: keys.apiTokens.list(),
    queryFn: ({ signal }) => api.get<ApiToken[]>("/api_tokens", { signal }),
  });

  return (
    <div className="space-y-10">
      <section className="space-y-4">
        <SectionHeader
          title="API tokens"
          description={`Long-lived credentials for your own scripts and integrations. Each one carries your access; revoking it is one click. An assistant connects over MCP at ${window.location.origin}/mcp with one of these as its bearer token.`}
          actions={
            <Button size="sm" variant="secondary" onClick={() => setAdding((v) => !v)}>
              <Plus className="h-4 w-4" aria-hidden /> New token
            </Button>
          }
        />
        {revealed ? <RevealedSecret name={revealed.name} secret={revealed.token} onDismiss={() => setRevealed(null)} /> : null}
        {adding ? (
          <div className="rounded-[var(--radius-card)] border border-border bg-surface p-4">
            <TokenForm
              onCreated={(created) => {
                setRevealed(created);
                setAdding(false);
              }}
              onCancel={() => setAdding(false)}
            />
          </div>
        ) : null}
        <QueryState
          query={list}
          errorMessage="Could not load tokens."
          empty={
            adding ? undefined : (
              <EmptyState
                title="No tokens yet"
                description="Create one to let a script or another app talk to Stream."
                action={<Button size="sm" onClick={() => setAdding(true)}>New token</Button>}
              />
            )
          }
        >
          {(tokens) => (
            <ul className="divide-y divide-border">
              {tokens.map((token) => (
                <TokenRow key={token.id} token={token} />
              ))}
            </ul>
          )}
        </QueryState>
      </section>
    </div>
  );
}

function TokenRow({ token }: { token: ApiToken }) {
  const queryClient = useQueryClient();
  const revoke = useMutation({
    mutationFn: () => api.delete(`/api_tokens/${token.id}`),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: keys.apiTokens.all }),
  });
  return (
    <li className="flex flex-wrap items-center justify-between gap-3 py-3">
      <div className="min-w-0">
        <p className="flex flex-wrap items-center gap-2">
          <span className="font-semibold text-foreground">{token.name}</span>
          {token.scope === "read" ? <Badge tone="neutral">read-only</Badge> : null}
          {token.expired ? <Badge tone="danger">expired</Badge> : null}
        </p>
        <p className="mt-0.5 font-mono text-xs text-muted">{token.prefix}…</p>
        <p className="mt-0.5 text-xs text-muted">
          {token.last_used_at ? `Last used ${relativeTime(token.last_used_at)}` : "Never used"}
          {token.expires_at ? ` · expires ${new Date(token.expires_at).toLocaleDateString()}` : " · no expiry"}
          {` · created ${relativeTime(token.created_at)}`}
        </p>
      </div>
      <ConfirmButton question="Revoke this token? Anything using it stops working." onConfirm={() => revoke.mutate()} disabled={revoke.isPending}>
        Revoke
      </ConfirmButton>
    </li>
  );
}

function TokenForm({ onCreated, onCancel }: { onCreated: (created: ApiTokenCreated) => void; onCancel: () => void }) {
  const queryClient = useQueryClient();
  const [name, setName] = useState("");
  const [days, setDays] = useState("");
  const create = useFormMutation({
    mutationFn: () =>
      api.post<ApiTokenCreated>("/api_tokens", { name, expires_in_days: days === "" ? undefined : Number(days) }),
    onSuccess: (created) => {
      void queryClient.invalidateQueries({ queryKey: keys.apiTokens.all });
      onCreated(created);
    },
    fallback: "Could not create the token",
  });

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    create.mutate();
  }

  return (
    <form onSubmit={onSubmit} className="space-y-4">
      <div className="grid gap-4 md:grid-cols-2">
        <Input label="Name" name="token_name" placeholder="yt-dlp on the NAS" value={name} onChange={(e) => setName(e.target.value)} required />
        <Input label="Expires in (days)" name="expires_in_days" type="number" min={1} max={3650} value={days} onChange={(e) => setDays(e.target.value)} hint="Leave blank for no expiry." />
      </div>
      <FormError message={create.errorMessage} />
      <FormFooter label="Create token" pendingLabel="Creating…" pending={create.isPending} disabled={name.trim() === ""} onCancel={onCancel} />
    </form>
  );
}
