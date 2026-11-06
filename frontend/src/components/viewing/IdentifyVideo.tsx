import { useState, type FormEvent } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { ExternalLink, Link2 } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { formatClock } from "@/lib/format";
import { useAuth } from "@/hooks/useAuth";
import { useFormMutation } from "@/hooks/useFormMutation";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { FormError } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import type { VideoDetail, VideoIdentity, YoutubeCandidate } from "@/types";

/** Still waiting for someone to say which YouTube video it is. */
const UNIDENTIFIED: readonly VideoIdentity[] = ["unchecked", "needs_review", "not_found"];

const INTRO: Record<VideoIdentity, string> = {
  unchecked: "Stream hasn't looked this one up on YouTube yet. Paste its link to fetch its details now.",
  needs_review: "Stream found videos like this one but wasn't sure enough to pick. Choose the right one, or paste its link.",
  not_found: "Nothing on the channel matched this video's title and length. If it's on YouTube, paste its link.",
  identified: "",
  not_on_youtube: "",
};

/**
 * Under a hand-placed video's description, for an admin (PROPOSAL §5.4):
 * which YouTube video it is, when Stream couldn't tell for sure. The closest
 * candidates, a pasted link, or "not on YouTube" — then its details, upload
 * date and thumbnail come from YouTube.
 */
export function IdentifyVideo({ video }: { video: VideoDetail }) {
  const { user } = useAuth();
  if (user?.role !== "admin" || !UNIDENTIFIED.includes(video.identity)) return null;
  return <IdentifyCard video={video} />;
}

function IdentifyCard({ video }: { video: VideoDetail }) {
  const queryClient = useQueryClient();
  const [link, setLink] = useState("");
  const refresh = () => {
    void queryClient.invalidateQueries({ queryKey: keys.videos.all });
    // The details arrive a few seconds later, from a job.
    window.setTimeout(() => void queryClient.invalidateQueries({ queryKey: keys.videos.detail(video.id) }), 8000);
  };
  const identify = useFormMutation({
    mutationFn: (choice: Choice) => api.post(`/videos/${video.id}/identify`, choice),
    onSuccess: refresh,
    fallback: "That didn't go through",
  });
  const dismiss = useFormMutation({
    mutationFn: () => api.post(`/videos/${video.id}/not_on_youtube`),
    onSuccess: refresh,
    fallback: "That didn't go through",
  });

  function onPaste(event: FormEvent) {
    event.preventDefault();
    identify.mutate({ url: link.trim() });
  }

  const busy = identify.isPending || dismiss.isPending;
  return (
    <Card>
      <CardHeader
        title="Which YouTube video is this?"
        description={INTRO[video.identity]}
        actions={
          <Button variant="ghost" size="sm" onClick={() => dismiss.mutate()} disabled={busy}>
            Not on YouTube
          </Button>
        }
      />
      <CardBody className="space-y-4">
        {video.youtube_candidates.length > 0 ? (
          <ul className="space-y-3" aria-label="Possible matches">
            {video.youtube_candidates.map((candidate) => (
              <CandidateRow
                key={candidate.youtube_id}
                candidate={candidate}
                onChoose={() => identify.mutate({ youtube_id: candidate.youtube_id })}
                pending={identify.isPending && chosen(identify.variables) === candidate.youtube_id}
                disabled={busy}
              />
            ))}
          </ul>
        ) : null}
        <form onSubmit={onPaste} className="flex flex-col gap-2 sm:flex-row sm:items-end">
          <div className="min-w-0 flex-1">
            <Input
              label="YouTube link"
              placeholder="https://www.youtube.com/watch?v=…"
              value={link}
              onChange={(event) => setLink(event.target.value)}
              icon={<Link2 className="h-4 w-4" />}
            />
          </div>
          <Button type="submit" variant="secondary" disabled={busy || !link.trim()}>
            Use this link
          </Button>
        </form>
        <FormError message={identify.errorMessage ?? dismiss.errorMessage} />
      </CardBody>
    </Card>
  );
}

type Choice = { youtube_id: string } | { url: string };

/** The candidate a pick is for, if it is a pick and not a pasted link. */
function chosen(choice: Choice | undefined): string | null {
  return choice && "youtube_id" in choice ? choice.youtube_id : null;
}

function CandidateRow({
  candidate,
  onChoose,
  pending,
  disabled,
}: {
  candidate: YoutubeCandidate;
  onChoose: () => void;
  pending: boolean;
  disabled: boolean;
}) {
  const url = `https://www.youtube.com/watch?v=${candidate.youtube_id}`;
  return (
    <li className="flex flex-wrap items-center gap-3 rounded-[var(--radius-card)] border border-border bg-surface p-3">
      <div className="aspect-video w-28 shrink-0 overflow-hidden rounded-[var(--radius-control)] bg-surface-raised sm:w-40">
        <img
          src={`https://i.ytimg.com/vi/${candidate.youtube_id}/mqdefault.jpg`}
          alt=""
          loading="lazy"
          // A video taken down since has no picture: the box stays empty.
          onError={(event) => event.currentTarget.remove()}
          className="h-full w-full object-cover"
        />
      </div>
      <div className="min-w-[10rem] flex-1 space-y-1">
        <p className="font-medium text-foreground">{candidate.title}</p>
        <p className="text-xs text-muted">
          {[candidate.duration_seconds ? formatClock(candidate.duration_seconds) : null, `${Math.round(candidate.score * 100)}%`, ...candidate.reasons]
            .filter(Boolean)
            .join(" · ")}
        </p>
        <a href={url} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 text-xs text-muted hover:text-foreground">
          <ExternalLink className="h-3.5 w-3.5" aria-hidden />
          Open on YouTube
        </a>
      </div>
      <Button size="sm" onClick={onChoose} disabled={disabled} className="shrink-0">
        {pending ? "Choosing…" : "This one"}
      </Button>
    </li>
  );
}
