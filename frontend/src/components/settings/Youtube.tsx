import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { api } from "@/api/client";
import { keys } from "@/lib/queryKeys";
import { relativeTime } from "@/lib/time";
import { useFormMutation } from "@/hooks/useFormMutation";
import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { FormError, FormFooter } from "@/components/ui/Form";
import { QueryState } from "@/components/ui/PageState";
import { Select } from "@/components/ui/Select";
import { Toggle } from "@/components/ui/Toggle";
import type { YoutubeStatus } from "@/types";

/**
 * Settings › YouTube (PROPOSAL §5.4): the one folder Stream downloads into,
 * the yt-dlp doing it, and the channels it follows.
 */
export function Youtube() {
  const status = useQuery({ queryKey: keys.youtube.status(), queryFn: ({ signal }) => api.get<YoutubeStatus>("/youtube", { signal }) });
  return (
    <QueryState query={status} errorMessage="Could not load YouTube settings.">
      {(data) => (
        <div className="space-y-6">
          <FolderCard status={data} />
          <ToolCard status={data} />
          <SponsorBlockCard status={data} />
          <EndScreenCard status={data} />
          <FollowingCard status={data} />
        </div>
      )}
    </QueryState>
  );
}

function FolderCard({ status }: { status: YoutubeStatus }) {
  const queryClient = useQueryClient();
  const current = status.libraries.find((library) => library.download_root);
  const [choice, setChoice] = useState(current ? `${current.id}|${current.download_root}` : "");
  const save = useFormMutation({
    fallback: "Couldn't set the download folder.",
    mutationFn: () => {
      const [library_id, download_root] = choice ? choice.split("|") : [null, null];
      return api.patch<YoutubeStatus>("/youtube", { library_id, download_root });
    },
    onSuccess: (data) => queryClient.setQueryData(keys.youtube.status(), data),
  });
  const options = status.libraries.flatMap((library) => library.roots.map((root) => ({ value: `${library.id}|${root}`, label: `${library.name} — ${root}` })));

  return (
    <Card>
      <CardHeader
        title="Download folder"
        description="YouTube is the one thing Stream fetches itself. Videos land here, a folder per channel, and the library reads them like any other."
      />
      <CardBody>
        {options.length === 0 ? (
          <p className="text-sm text-muted">
            Add a Channels library first, in <Link to="/settings?tab=libraries" className="text-primary hover:underline">Libraries</Link>, with a folder Stream can write to.
          </p>
        ) : (
          <form
            className="space-y-4"
            onSubmit={(event) => {
              event.preventDefault();
              save.mutate();
            }}
          >
            <Select label="Folder" name="download-folder" value={choice} onChange={(event) => setChoice(event.target.value)} hint="It must be writable.">
              <option value="">Don't download from YouTube</option>
              {options.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </Select>
            <FormError message={save.errorMessage} />
            <FormFooter label="Save" pending={save.isPending} />
          </form>
        )}
      </CardBody>
    </Card>
  );
}

function ToolCard({ status }: { status: YoutubeStatus }) {
  const update = useMutation({ mutationFn: () => api.post("/youtube/update_tool") });
  const counts = status.downloads;
  return (
    <Card>
      <CardHeader
        title="yt-dlp"
        description={status.yt_dlp_version ? `Version ${status.yt_dlp_version}. Updated daily; YouTube changes under it often.` : "Not found on this server."}
        actions={
          <Button variant="secondary" size="sm" onClick={() => update.mutate()} disabled={update.isPending || update.isSuccess}>
            {update.isSuccess ? "Updating…" : "Update now"}
          </Button>
        }
      />
      <CardBody>
        <p className="text-sm text-muted">
          {counts.done} downloaded · {counts.queued + counts.downloading} on the way · {counts.failed} failed · {counts.skipped} skipped by rules
        </p>
      </CardBody>
    </Card>
  );
}

function FollowingCard({ status }: { status: YoutubeStatus }) {
  return (
    <Card>
      <CardHeader title="Following" description="Channels checked for new videos. Add one from a Channels library's page." />
      <CardBody>
        {status.tracked.length === 0 ? (
          <p className="text-sm text-muted">None yet.</p>
        ) : (
          <ul className="divide-y divide-border text-sm">
            {status.tracked.map((channel) => (
              <li key={channel.id} className="flex flex-wrap items-center justify-between gap-2 py-2">
                <Link to={`/channel/${channel.id}`} className="font-medium text-foreground hover:underline">
                  {channel.title}
                </Link>
                <span className={channel.last_poll_error ? "text-negative" : "text-muted"}>
                  {channel.last_poll_error ?? (channel.last_polled_at ? `checked ${relativeTime(channel.last_polled_at)}` : "not checked yet")}
                </span>
              </li>
            ))}
          </ul>
        )}
      </CardBody>
    </Card>
  );
}

function EndScreenCard({ status }: { status: YoutubeStatus }) {
  const queryClient = useQueryClient();
  const toggle = useMutation({
    mutationFn: (enabled: boolean) => api.patch<YoutubeStatus>("/youtube/end_screen", { enabled }),
    onSuccess: (data) => {
      queryClient.setQueryData(keys.youtube.status(), data);
      // Watch pages carry what they'll offer at the end.
      void queryClient.invalidateQueries({ queryKey: keys.videos.all });
    },
  });
  return (
    <Card>
      <CardHeader title="End screen" description="When a video finishes with nothing queued after it, what to watch next is laid over its last frame." />
      <CardBody>
        <Toggle
          label="Suggest videos at the end"
          hint="One more from the same channel, and a few from other channels. For every profile."
          checked={status.end_screen}
          disabled={toggle.isPending}
          onChange={(enabled) => toggle.mutate(enabled)}
        />
      </CardBody>
    </Card>
  );
}

function SponsorBlockCard({ status }: { status: YoutubeStatus }) {
  const queryClient = useQueryClient();
  const toggle = useMutation({
    mutationFn: ({ libraryId, enabled }: { libraryId: string; enabled: boolean }) =>
      api.patch<YoutubeStatus>("/youtube/sponsorblock", { library_id: libraryId, enabled }),
    onSuccess: (data) => queryClient.setQueryData(keys.youtube.status(), data),
  });
  if (status.libraries.length === 0) return null;
  return (
    <Card>
      <CardHeader
        title="SponsorBlock"
        description="The community's marks for sponsor reads and the like, fetched for these libraries' videos. Each profile chooses what to skip in Settings › Viewing."
      />
      <CardBody className="space-y-3">
        {status.libraries.map((library) => (
          <Toggle
            key={library.id}
            label={library.name}
            checked={library.sponsorblock}
            disabled={toggle.isPending}
            onChange={(enabled) => toggle.mutate({ libraryId: library.id, enabled })}
          />
        ))}
      </CardBody>
    </Card>
  );
}
