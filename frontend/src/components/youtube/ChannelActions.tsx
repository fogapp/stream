import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { useQueryClient } from "@tanstack/react-query";
import { ArrowLeft, Ban, Bell, BellOff, ExternalLink, Eye, EyeOff, RefreshCw, UserMinus, UserRound } from "lucide-react";
import { api, apiErrorMessage } from "@/api/client";
import { useAuth } from "@/hooks/useAuth";
import { keys } from "@/lib/queryKeys";
import { refreshWatched } from "@/lib/watched";
import { useHideFromProfile } from "@/components/viewing/HideFromProfile";
import { ActionMenu, ActionMenuItem, ActionMenuSeparator } from "@/components/ui/ActionMenu";
import { toast } from "@/components/ui/Toast";
import type { ChannelListItem } from "@/types";

/**
 * The "…" on a channel in a channels library's list: its page, its videos
 * watched, this profile's subscription, YouTube, and — for an admin, on a
 * followed channel — a check for new uploads or no more following.
 */
export function ChannelActions({ channel, onHidden, className }: { channel: ChannelListItem; onHidden?: () => void; className?: string }) {
  return (
    <ActionMenu label={`More for ${channel.title}`} className={className}>
      {(close) => <ChannelActionList channel={channel} onHidden={onHidden} close={close} />}
    </ActionMenu>
  );
}

function ChannelActionList({ channel, onHidden, close }: { channel: ChannelListItem; onHidden?: () => void; close: () => void }) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { user } = useAuth();
  const hiding = useHideFromProfile({ kind: "channel", id: channel.id, title: channel.title }, onHidden);
  const [confirmingHide, setConfirmingHide] = useState(false);
  const admin = user?.role === "admin";

  // `refresh`: the keys the change moves, or "watched" for everything a
  // watched change can (lib/watched).
  const run = (work: Promise<unknown>, done: string, refresh: ReadonlyArray<readonly string[]> | "watched") => {
    close();
    work
      .then(() => {
        if (refresh === "watched") refreshWatched(queryClient);
        else for (const key of refresh) void queryClient.invalidateQueries({ queryKey: key });
        toast.info(done);
      })
      .catch((error: unknown) => toast.error(apiErrorMessage(error, "That didn't go through.")));
  };

  if (confirmingHide && hiding) {
    return (
      <>
        <ActionMenuItem icon={<ArrowLeft className="h-4 w-4" aria-hidden />} onSelect={() => setConfirmingHide(false)} autoFocus>
          Back
        </ActionMenuItem>
        <ActionMenuSeparator label={`Hide from ${hiding.profileName} everywhere?`} />
        <ActionMenuItem
          icon={<Ban className="h-4 w-4" aria-hidden />}
          disabled={hiding.pending}
          onSelect={() => {
            hiding.hide();
            close();
          }}
        >
          Hide {channel.title}
        </ActionMenuItem>
      </>
    );
  }

  const url = channel.url;
  const allWatched = channel.video_count > 0 && channel.unwatched_count === 0;

  return (
    <>
      <ActionMenuItem icon={<UserRound className="h-4 w-4" aria-hidden />} onSelect={() => navigate(`/channel/${channel.id}`)}>
        Go to channel page
      </ActionMenuItem>
      <ActionMenuItem
        icon={allWatched ? <EyeOff className="h-4 w-4" aria-hidden /> : <Eye className="h-4 w-4" aria-hidden />}
        onSelect={() =>
          run(
            api.post(`/channels/${channel.id}/watched`, { watched: !allWatched }),
            `${channel.title}: every video marked ${allWatched ? "unwatched" : "watched"}`,
            "watched",
          )
        }
      >
        {allWatched ? "Mark all as unwatched" : "Mark all as watched"}
      </ActionMenuItem>
      {admin && channel.tracked ? (
        <ActionMenuItem
          icon={<RefreshCw className="h-4 w-4" aria-hidden />}
          onSelect={() => run(api.post(`/channels/${channel.id}/tracking/poll`), `Checking ${channel.title} for new videos`, [keys.youtube.all])}
        >
          Check for new videos
        </ActionMenuItem>
      ) : null}
      <ActionMenuItem
        icon={channel.subscribed ? <BellOff className="h-4 w-4" aria-hidden /> : <Bell className="h-4 w-4" aria-hidden />}
        onSelect={() =>
          run(
            channel.subscribed ? api.delete(`/channels/${channel.id}/subscription`) : api.post(`/channels/${channel.id}/subscription`),
            channel.subscribed ? `Unsubscribed from ${channel.title}` : `Subscribed to ${channel.title}`,
            [keys.channels.all, keys.subscriptions.all, keys.home.all],
          )
        }
      >
        {channel.subscribed ? "Unsubscribe" : "Subscribe"}
      </ActionMenuItem>
      {url ? (
        <ActionMenuItem
          icon={<ExternalLink className="h-4 w-4" aria-hidden />}
          onSelect={() => {
            close();
            window.open(url, "_blank", "noopener,noreferrer");
          }}
        >
          Open on YouTube
        </ActionMenuItem>
      ) : null}
      {(admin && channel.tracked) || hiding ? <ActionMenuSeparator /> : null}
      {admin && channel.tracked ? (
        <ActionMenuItem
          icon={<UserMinus className="h-4 w-4" aria-hidden />}
          onSelect={() =>
            run(
              api.patch(`/channels/${channel.id}/tracking`, { tracked: false }),
              `Stopped following ${channel.title}. What's downloaded stays.`,
              [keys.channels.all, keys.youtube.all],
            )
          }
        >
          Unfollow
        </ActionMenuItem>
      ) : null}
      {hiding ? (
        <ActionMenuItem icon={<Ban className="h-4 w-4" aria-hidden />} onSelect={() => setConfirmingHide(true)}>
          Hide from me…
        </ActionMenuItem>
      ) : null}
    </>
  );
}

