import { useState, type FormEvent } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Link2 } from "lucide-react";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { useFormMutation } from "@/hooks/useFormMutation";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { FormError } from "@/components/ui/Form";
import { Input } from "@/components/ui/Input";
import type { ChannelTracking } from "@/types";

/**
 * A channel made from a folder, told which YouTube channel it is (PROPOSAL
 * §5.4): its name, picture, banner and description come from YouTube, and
 * its videos are looked up there. Nothing is followed or downloaded — that's
 * the Following card this one makes way for.
 */
export function LinkChannel({ channelId }: { channelId: string }) {
  const queryClient = useQueryClient();
  const [url, setUrl] = useState("");
  const link = useFormMutation({
    fallback: "Couldn't link the channel.",
    mutationFn: () => api.post<ChannelTracking>(`/channels/${channelId}/tracking/link`, { url: url.trim() }),
    onSuccess: (data) => {
      queryClient.setQueryData(keys.youtube.tracking(channelId), data);
      void queryClient.invalidateQueries({ queryKey: keys.channels.all });
      void queryClient.invalidateQueries({ queryKey: keys.videos.all });
    },
  });

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    link.mutate();
  }

  return (
    <Card>
      <CardHeader
        title="Link to YouTube"
        description="Paste this channel's YouTube link to fill in its name, picture and description, and to find each of its videos there. Nothing is downloaded."
      />
      <CardBody className="space-y-3">
        <form onSubmit={onSubmit} className="flex flex-col gap-2 sm:flex-row sm:items-end">
          <div className="min-w-0 flex-1">
            <Input
              label="Channel link"
              placeholder="https://www.youtube.com/@name"
              value={url}
              onChange={(event) => setUrl(event.target.value)}
              icon={<Link2 className="h-4 w-4" />}
            />
          </div>
          <Button type="submit" disabled={link.isPending || !url.trim()}>
            {link.isPending ? "Asking YouTube…" : "Link"}
          </Button>
        </form>
        <FormError message={link.errorMessage} />
      </CardBody>
    </Card>
  );
}
