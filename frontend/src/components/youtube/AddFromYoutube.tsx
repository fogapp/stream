import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "react-router-dom";
import { Search, X } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { useFormMutation } from "@/hooks/useFormMutation";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { FormError } from "@/components/ui/Form";
import { IconButton } from "@/components/ui/IconButton";
import { Input } from "@/components/ui/Input";
import { DEFAULT_RULES, TrackingRulesForm } from "@/components/youtube/TrackingRulesForm";
import type { TrackingRules, YoutubePreview } from "@/types";

/**
 * Add channel (PROPOSAL §5.4): paste a channel, video or playlist link, see
 * what it is, choose the rules, and Stream takes it from there.
 */
export function AddFromYoutube({ onDone }: { onDone: () => void }) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [url, setUrl] = useState("");
  const [rules, setRules] = useState<TrackingRules>(DEFAULT_RULES);
  const lookup = useFormMutation({
    fallback: "Couldn't look that link up.",
    mutationFn: () => api.post<YoutubePreview>("/youtube/resolve", { url }),
  });
  const track = useFormMutation({
    fallback: "Couldn't add it.",
    mutationFn: () => api.post<{ channel_id: string | null; queued: number }>("/youtube/track", { url, rules }),
    onSuccess: (result) => {
      void queryClient.invalidateQueries({ queryKey: keys.channels.all });
      void queryClient.invalidateQueries({ queryKey: keys.youtube.all });
      onDone();
      if (result.channel_id) navigate(`/channel/${result.channel_id}`);
    },
  });
  const preview = lookup.data;

  return (
    <Card>
      <CardHeader
        title="Add from YouTube"
        description="A channel to follow from now on, or a single video or playlist to fetch once."
        actions={
          <IconButton label="Close" onClick={onDone}>
            <X className="h-4 w-4" aria-hidden />
          </IconButton>
        }
      />
      <CardBody className="space-y-5">
        <form
          className="flex flex-col gap-2 sm:flex-row"
          onSubmit={(event) => {
            event.preventDefault();
            if (url.trim()) lookup.mutate();
          }}
        >
          <div className="flex-1">
            <Input
              aria-label="YouTube link"
              placeholder="youtube.com/@channel, a video or a playlist link"
              value={url}
              onChange={(event) => {
                setUrl(event.target.value);
                lookup.reset();
              }}
              icon={<Search className="h-4 w-4" aria-hidden />}
            />
          </div>
          <Button type="submit" variant="secondary" disabled={!url.trim() || lookup.isPending}>
            {lookup.isPending ? "Looking…" : "Look up"}
          </Button>
        </form>
        <FormError message={lookup.errorMessage} />

        {preview ? (
          <div className="space-y-5">
            <div className="flex items-center gap-3">
              {preview.channel?.avatar_url ? (
                <img src={preview.channel.avatar_url} alt="" referrerPolicy="no-referrer" className="h-12 w-12 rounded-full ring-1 ring-border" />
              ) : null}
              <div className="min-w-0">
                <p className="truncate font-medium text-foreground">
                  {preview.kind === "channel" ? preview.channel?.title : preview.title}
                </p>
                <p className="truncate text-sm text-muted">
                  {preview.kind === "channel"
                    ? [preview.channel?.handle, preview.channel?.tracked ? "already followed" : null].filter(Boolean).join(" · ")
                    : preview.kind === "video"
                      ? `A video by ${preview.channel?.title ?? "someone"} · downloaded and kept`
                      : `A playlist of ${preview.videos.length} videos`}
                </p>
              </div>
            </div>
            {preview.kind === "channel" ? <TrackingRulesForm rules={rules} onChange={setRules} firstTime /> : null}
            <FormError message={track.errorMessage} />
            <div className="flex gap-2">
              <Button onClick={() => track.mutate()} disabled={track.isPending}>
                {track.isPending
                  ? "Adding…"
                  : preview.kind === "channel"
                    ? "Follow channel"
                    : preview.kind === "video"
                      ? "Download video"
                      : `Download ${preview.videos.length} videos`}
              </Button>
              <Button variant="ghost" onClick={onDone}>
                Cancel
              </Button>
            </div>
          </div>
        ) : null}
      </CardBody>
    </Card>
  );
}
