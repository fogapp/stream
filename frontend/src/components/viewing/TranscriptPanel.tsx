import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { Search } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { formatClock } from "@/lib/format";
import { DisclosureButton } from "@/components/ui/DisclosureButton";
import { Input } from "@/components/ui/Input";
import type { PlayableKind, TranscriptInfo } from "@/types";

/** What was said, line by line (PROPOSAL §5.5): find a moment, press it to play from there. */
export function TranscriptPanel({ kind, id }: { kind: PlayableKind; id: string }) {
  const [open, setOpen] = useState(false);
  const [filter, setFilter] = useState("");
  const transcript = useQuery({
    queryKey: keys.transcripts.detail(kind, id),
    queryFn: ({ signal }) => api.get<TranscriptInfo>(`/transcript?playable_type=${kind}&playable_id=${id}`, { signal }),
  });
  const lines = useMemo(() => {
    const all = transcript.data?.lines ?? [];
    const words = filter.trim().toLowerCase();
    return words ? all.filter((line) => line.text.toLowerCase().includes(words)) : all;
  }, [transcript.data, filter]);

  if (!transcript.data?.available) return null;
  return (
    <section className="space-y-3">
      <DisclosureButton
        open={open}
        onToggle={() => setOpen((value) => !value)}
        label={transcript.data.source === "whisper" ? "Transcript (auto-generated)" : "Transcript"}
      />
      {open ? (
        <div className="space-y-2">
          <Input
            aria-label="Search the transcript"
            placeholder="Search the transcript"
            value={filter}
            onChange={(event) => setFilter(event.target.value)}
            icon={<Search className="h-4 w-4" aria-hidden />}
          />
          <ol className="max-h-96 overflow-y-auto rounded-[var(--radius-card)] border border-border">
            {lines.map((line) => (
              <li key={line.start}>
                {/* A video plays in its own page; everything else in the full-window player. */}
                <Link to={kind === "video" ? `/video/${id}?t=${Math.floor(line.start)}` : `/watch/${kind}/${id}?t=${Math.floor(line.start)}`} className="flex gap-3 px-3 py-1.5 text-sm hover:bg-surface">
                  <span className="w-14 shrink-0 font-mono tabular-nums text-primary">{formatClock(line.start)}</span>
                  <span className="text-foreground/90">{line.text}</span>
                </Link>
              </li>
            ))}
            {lines.length === 0 ? <li className="px-3 py-4 text-center text-sm text-muted">Not said in this one.</li> : null}
          </ol>
        </div>
      ) : null}
    </section>
  );
}
