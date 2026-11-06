import { Link } from "react-router-dom";
import { Bell, BellOff, Info, PictureInPicture2, Play, Radio } from "lucide-react";
import { AiringDetails } from "@/components/live/AiringDetails";
import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import type { Airing, Station } from "@/types";

/**
 * A program chosen in the guide (PROPOSAL §7.7): watch its channel if it's
 * on, be reminded if it's to come, or — it's the household's own library —
 * watch it now from the start.
 */
export function AiringSheet({
  airing,
  station,
  timeZone,
  now,
  admin,
  onTune,
  onPip,
  onRemind,
  onClose,
}: {
  airing: Airing;
  station: Station;
  timeZone: string;
  now: number;
  admin: boolean;
  onTune: () => void;
  /** While something else plays: the channel in the inset over it (picture in picture). */
  onPip?: () => void;
  onRemind: (remind: boolean) => void;
  onClose: () => void;
}) {
  // A stream's channel: the stream is always on, and there's nothing to be
  // reminded of. A game on a scheduled channel is a stream too, in its slot.
  const stream = airing.kind === "live_stream";
  const always = Boolean(station.live_stream_id);
  const onNow = always || (Date.parse(airing.starts_at) <= now && Date.parse(airing.ends_at) > now);
  const upcoming = !always && Date.parse(airing.starts_at) > now;
  const titlePath =
    airing.kind === "movie"
      ? `/movie/${airing.playable_id}`
      : airing.show_id
        ? `/show/${airing.show_id}`
        : airing.channel_id
          ? `/channel/${airing.channel_id}`
          : null;
  const titleLabel = airing.kind === "movie" ? "About the film" : airing.kind === "video" ? "About the channel" : "About the show";
  return (
    <Dialog label={`${airing.title}${airing.subtitle ? `, ${airing.subtitle}` : ""}`} onClose={onClose} className="max-w-xl">
      <div className="space-y-5 pt-6">
        <AiringDetails airing={airing} station={station} timeZone={timeZone} showReason={admin} />
        <div className="flex flex-wrap gap-2">
          {onNow ? (
            <Button data-tv onClick={onTune}>
              <Radio className="h-4 w-4" aria-hidden />
              Watch channel {station.number}
            </Button>
          ) : null}
          {onNow && onPip ? (
            <Button variant="secondary" onClick={onPip}>
              <PictureInPicture2 className="h-4 w-4" aria-hidden />
              Picture in picture
            </Button>
          ) : null}
          {upcoming ? (
            <Button data-tv variant={airing.reminded ? "secondary" : "primary"} onClick={() => onRemind(!airing.reminded)}>
              {airing.reminded ? <BellOff className="h-4 w-4" aria-hidden /> : <Bell className="h-4 w-4" aria-hidden />}
              {airing.reminded ? "Don't remind me" : "Remind me"}
            </Button>
          ) : null}
          {stream && !onNow ? null : (
            <Link to={stream ? `/stream/${airing.playable_id}` : `/watch/${airing.kind}/${airing.playable_id}?from=start`}>
              <Button data-tv variant="secondary">
                <Play className="h-4 w-4" aria-hidden />
                {stream ? "Watch on its own" : "Watch now from the start"}
              </Button>
            </Link>
          )}
          {titlePath ? (
            <Link to={titlePath}>
              <Button variant="ghost">
                <Info className="h-4 w-4" aria-hidden />
                {titleLabel}
              </Button>
            </Link>
          ) : null}
        </div>
      </div>
    </Dialog>
  );
}
