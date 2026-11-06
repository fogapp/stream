import { useState, type FormEvent } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Plus } from "lucide-react";
import { api } from "@/api/client";
import { useFormMutation } from "@/hooks/useFormMutation";
import { ENCODER_LABELS } from "@/lib/encoders";
import { keys } from "@/lib/queryKeys";
import { relativeTime } from "@/lib/time";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { CodeBlock } from "@/components/ui/CodeBlock";
import { ConfirmButton } from "@/components/ui/ConfirmButton";
import { FormError, FormFooter } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import { EmptyState, QueryState } from "@/components/ui/PageState";
import { RevealedSecret } from "@/components/ui/RevealedSecret";
import { SectionHeader } from "@/components/ui/SectionHeader";
import { Select } from "@/components/ui/Select";
import { Toggle } from "@/components/ui/Toggle";
import type { TranscodeNode, TranscodeNodeCreated, TranscodeNodeList } from "@/types";

/**
 * Settings › Transcoders (PROPOSAL §11 Phase 6): other machines that
 * convert video for Stream — a Mac mini with VideoToolbox, say. Each runs
 * one small script that polls this server; nothing about the network or
 * the NAS needs setting up on it.
 */
export function Transcoders() {
  const [adding, setAdding] = useState(false);
  const [revealed, setRevealed] = useState<TranscodeNodeCreated | null>(null);
  const list = useQuery({
    queryKey: keys.transcodeNodes.list(),
    queryFn: ({ signal }) => api.get<TranscodeNodeList>("/transcode_nodes", { signal }),
    refetchInterval: 10_000,
  });

  return (
    <section className="space-y-4">
      <SectionHeader
        title="Transcoders"
        description="Machines besides this server that convert video, used when they're online. Hardware encoders are chosen first; repackaging always happens here."
        actions={
          <Button size="sm" variant="secondary" onClick={() => setAdding((value) => !value)}>
            <Plus className="h-4 w-4" aria-hidden /> Add a transcoder
          </Button>
        }
      />
      {revealed ? (
        <RevealedSecret name={revealed.name} secret={revealed.token} onDismiss={() => setRevealed(null)}>
          <p className="text-sm text-muted">On {revealed.name}, with ffmpeg installed (on a Mac: brew install ffmpeg), run:</p>
          <CodeBlock value={command(revealed.token)} copyable />
        </RevealedSecret>
      ) : null}
      {adding ? (
        <div className="rounded-[var(--radius-card)] border border-border bg-surface p-4">
          <AddForm
            onCreated={(created) => {
              setRevealed(created);
              setAdding(false);
            }}
            onCancel={() => setAdding(false)}
          />
        </div>
      ) : null}
      <QueryState query={list} errorMessage="Could not load transcoders.">
        {(data) => (
          <div className="space-y-4">
            <p className="text-sm text-muted">
              This server converts with {data.local.encoder ? ENCODER_LABELS[data.local.encoder] : "its CPU"}, {data.local.cap} at a time. With the transcoders online, {data.capacity} at once.
            </p>
            {data.nodes.length === 0 ? (
              adding ? null : (
                <EmptyState
                  title="No other transcoders"
                  description="Add one to convert on another machine, like a Mac with Apple's media engine."
                  action={<Button size="sm" onClick={() => setAdding(true)}>Add a transcoder</Button>}
                />
              )
            ) : (
              <ul className="divide-y divide-border rounded-[var(--radius-card)] border border-border">
                {data.nodes.map((node) => (
                  <NodeRow key={node.id} node={node} />
                ))}
              </ul>
            )}
          </div>
        )}
      </QueryState>
    </section>
  );
}

function command(token: string): string {
  const origin = window.location.origin;
  return `curl -fsSL ${origin}/api/v1/transcoder/worker -o stream-transcode-worker\nruby stream-transcode-worker --server ${origin} --token ${token}`;
}

const SESSION_CHOICES = [1, 2, 3, 4, 5, 6, 7, 8] as const;

function NodeRow({ node }: { node: TranscodeNode }) {
  const queryClient = useQueryClient();
  const refresh = () => queryClient.invalidateQueries({ queryKey: keys.transcodeNodes.all });
  const update = useMutation({
    mutationFn: (changes: Partial<Pick<TranscodeNode, "enabled" | "optimize" | "max_sessions">>) =>
      api.patch<TranscodeNode>(`/transcode_nodes/${node.id}`, changes),
    onSuccess: refresh,
  });
  const remove = useMutation({ mutationFn: () => api.delete(`/transcode_nodes/${node.id}`), onSuccess: refresh });

  return (
    <li className="space-y-3 px-4 py-3 text-sm">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-semibold text-foreground">{node.name}</span>
        {!node.enabled ? <Badge tone="neutral">Off</Badge> : node.online ? <Badge tone="success">Online</Badge> : <Badge tone="warning">Offline</Badge>}
        {node.encoder ? <Badge tone="info">{ENCODER_LABELS[node.encoder]}</Badge> : null}
        {node.fog_pool ? <Badge tone="neutral">Provided by fog</Badge> : null}
        <span className="text-muted">
          {node.last_seen_at ? `seen ${relativeTime(node.last_seen_at)}` : "never connected"}
          {node.hostname ? ` · ${node.hostname}` : ""}
        </span>
      </div>
      {node.ffmpeg ? <p className="text-xs text-muted">{node.ffmpeg} · tone mapping: {node.tone_mapping}</p> : null}
      {node.fog_free ? (
        <p className="text-xs text-muted">
          fog runs this on whichever of its machines has room, and sets its room from them: {node.max_sessions} videos at once
          now, {node.fog_free.interactive} free. Machines are added in fog's System › Compute.
        </p>
      ) : null}
      {!node.last_seen_at && !node.fog_pool ? (
        <p className="text-xs text-muted">
          Waiting for its first poll. The token starts <span className="font-mono">{node.token_prefix}…</span>
        </p>
      ) : null}
      {node.runs.length > 0 ? (
        <ul className="space-y-1 text-muted">
          {node.runs.map((run) => (
            <li key={run.id}>
              {run.kind === "optimize" ? "Optimizing" : "Converting"} {run.title ?? "a video"} <span className="text-xs">({run.state})</span>
            </li>
          ))}
        </ul>
      ) : null}
      <div className="grid gap-3 sm:grid-cols-3">
        <Toggle label="Use it" checked={node.enabled} onChange={(enabled) => update.mutate({ enabled })} disabled={update.isPending} />
        <Toggle
          label="Optimize when idle"
          hint="Encodes optimized versions in quiet hours."
          checked={node.optimize}
          onChange={(optimize) => update.mutate({ optimize })}
          disabled={update.isPending}
        />
        {node.fog_pool ? null : (
          <Select
            label="Videos at once"
            value={String(node.max_sessions)}
            onChange={(event) => update.mutate({ max_sessions: Number(event.target.value) })}
            disabled={update.isPending}
          >
            {SESSION_CHOICES.map((count) => (
              <option key={count} value={count}>
                {count}
              </option>
            ))}
          </Select>
        )}
      </div>
      {node.fog_pool ? null : (
        <ConfirmButton size="sm" variant="ghost" question="Remove it? Its sessions carry on here." onConfirm={() => remove.mutate()} disabled={remove.isPending}>
          Remove
        </ConfirmButton>
      )}
    </li>
  );
}

function AddForm({ onCreated, onCancel }: { onCreated: (created: TranscodeNodeCreated) => void; onCancel: () => void }) {
  const queryClient = useQueryClient();
  const [name, setName] = useState("");
  const create = useFormMutation({
    mutationFn: () => api.post<TranscodeNodeCreated>("/transcode_nodes", { name }),
    onSuccess: (created) => {
      void queryClient.invalidateQueries({ queryKey: keys.transcodeNodes.all });
      onCreated(created);
    },
    fallback: "Could not add the transcoder",
  });

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    create.mutate();
  }

  return (
    <form onSubmit={onSubmit} className="space-y-4">
      <Input label="Name" name="transcoder_name" placeholder="Mac mini" value={name} onChange={(event) => setName(event.target.value)} required />
      <FormError message={create.errorMessage} />
      <FormFooter label="Add" pendingLabel="Adding…" pending={create.isPending} disabled={name.trim() === ""} onCancel={onCancel} />
    </form>
  );
}
