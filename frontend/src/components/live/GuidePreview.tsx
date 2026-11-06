import { useEffect, useRef, useState } from "react";
import { Volume2, VolumeX } from "lucide-react";
import { playOrMute } from "@/components/player/audio";
import { attachSource } from "@/components/player/source";
import { prefersNativeHls } from "@/lib/capabilities";
import { IconButton } from "@/components/ui/IconButton";
import { ArtworkImage } from "@/components/viewing/ArtworkImage";
import { cn } from "@/lib/cn";
import { clockSkew, liveOffset } from "@/lib/live";
import { liveHandoff } from "@/lib/liveHandoff";
import { createSession, releaseSession } from "@/lib/playbackSession";
import { rememberMuted, storedVolume } from "@/lib/volume";
import type { Airing, ImageInfo, PlaybackSessionInfo } from "@/types";

/** How long a channel has to stay focused before its preview is tuned. */
const SETTLE_MS = 600;

/**
 * The guide's preview window (PROPOSAL §7.7): the focused channel, live and
 * muted, over its program's still until the picture arrives. Tuned on
 * standby (never a play), let go when the focus moves on, and handed to
 * the channel's page when it's chosen — and handed back by that page when
 * it's left for the guide, so the channel carries on here: the page's own
 * element, still playing, as far into the program as it was. A channel that
 * would need converting shows its still. With `sound` it has a mute
 * button: muted until that's pressed, except back from a channel that was
 * playing aloud, whose sound carries on too.
 */
export function GuidePreview({
  stationId,
  airing,
  image,
  sound = false,
}: {
  stationId: string | null;
  airing: Airing | null;
  image: ImageInfo | null | undefined;
  sound?: boolean;
}) {
  const video = useRef<HTMLVideoElement>(null);
  const box = useRef<HTMLDivElement>(null);
  /** The channel page's element, handed over playing, in place of this one's. */
  const [adopted, setAdopted] = useState<HTMLVideoElement | null>(null);
  const [picture, setPicture] = useState(false);
  const [muted, setMuted] = useState(() => !sound || liveHandoff.leftVolume() === 0);
  const [volume, setVolume] = useState(() => liveHandoff.leftVolume() || storedVolume());
  const mutedRef = useRef(muted);
  mutedRef.current = muted;
  useEffect(() => {
    const element = adopted ?? video.current;
    if (!element) return;
    element.volume = volume;
    element.muted = muted;
  }, [muted, volume, adopted]);
  const onNow = airing ? Date.parse(airing.starts_at) <= Date.now() && Date.parse(airing.ends_at) > Date.now() : false;
  const airingId = airing?.id;

  useEffect(() => {
    setPicture(false);
    const element = video.current;
    const container = box.current;
    if (!stationId || !onNow || !element || !container) return;
    let session: PlaybackSessionInfo | null = null;
    let skew = 0;
    let detach: (() => void) | null = null;
    let cancelled = false;
    // Just left for the guide: its session is waiting, and there's nothing to settle.
    const timer = window.setTimeout(() => {
      const handed = liveHandoff.take(stationId, { picture: true });
      // How loud the channel was, read now: the guide can render before its
      // page has said it was left (the first render's guess may be stale).
      const level = sound && handed ? liveHandoff.leftVolume() : 0;
      if (level > 0) {
        mutedRef.current = false;
        setMuted(false);
        setVolume(level);
      }
      const handedPicture = handed?.picture;
      if (handed && handedPicture) {
        // The page's own element, moved in as it plays: nothing reloads, and
        // it stays where it was in the program.
        const adoptee = handedPicture.element;
        session = handed.session;
        skew = handed.skew;
        adoptee.className = "absolute inset-0 h-full w-full bg-background object-cover";
        adoptee.volume = level || volume;
        adoptee.muted = mutedRef.current;
        element.after(adoptee);
        if (handedPicture.playing && adoptee.paused) void adoptee.play().catch(() => undefined);
        detach = () => {
          handedPicture.detach();
          adoptee.remove();
          setAdopted(null);
        };
        setAdopted(adoptee);
        setPicture(true);
        return;
      }
      const request = handed
        ? Promise.resolve(handed.session)
        : createSession({ station_id: stationId, standby: true });
      request
        .then((tuned) => {
          if (cancelled) {
            releaseSession(tuned);
            return;
          }
          session = tuned;
          const live = tuned.live;
          skew = handed ? handed.skew : live ? clockSkew(live.server_now) : 0;
          // Seconds into the file: a part of a program starts partway in.
          // A stream's channel (PROPOSAL §7.8) is a live playlist: it opens at its newest.
          const stream = Boolean(tuned.live_stream);
          const at = () => (stream ? -1 : live ? live.media_start + liveOffset(live, Date.now() + skew) : tuned.resume_at);
          const nativeHls = tuned.source.kind === "hls" && prefersNativeHls();
          element.muted = mutedRef.current;
          detach = attachSource(element, tuned.source, at(), nativeHls, { onFailure: () => setPicture(false), onUnsupported: () => undefined }, { maxBufferLength: 20, live: stream }).detach;
          element.addEventListener(
            "loadedmetadata",
            () => {
              if (!stream && at() < element.duration - 0.5) element.currentTime = at();
              playOrMute(element, () => setMuted(true));
            },
            { once: true },
          );
        })
        .catch(() => undefined);
    }, liveHandoff.has(stationId) ? 0 : SETTLE_MS);
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
      detach?.();
      // Chosen: the channel's page picks it up; otherwise it's let go.
      if (session && container.dataset.handoff === stationId) liveHandoff.put(stationId, session, skew);
      else if (session) releaseSession(session);
      delete container.dataset.handoff;
    };
    // The volume is read once, on its way in.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [stationId, airingId, onNow]);

  return (
    <div
      ref={box}
      className="relative aspect-video w-40 shrink-0 overflow-hidden rounded-[var(--radius-control)] bg-surface-raised sm:w-84"
      data-testid="guide-preview"
    >
      <ArtworkImage image={image} sizes="336px" className="h-full w-full object-cover" />
      <video
        ref={video}
        hidden={adopted !== null}
        muted={muted}
        playsInline
        className={cn("absolute inset-0 h-full w-full bg-background object-cover transition-opacity", picture ? "opacity-100" : "opacity-0")}
        onPlaying={() => setPicture(true)}
      />
      {sound && picture ? (
        <IconButton
          label={muted ? "Unmute the preview" : "Mute the preview"}
          size="sm"
          onClick={() => {
            rememberMuted(!muted);
            setMuted(!muted);
          }}
          className="absolute bottom-1 right-1 bg-background/70 text-foreground hover:bg-background"
        >
          {muted ? <VolumeX className="h-4 w-4" aria-hidden /> : <Volume2 className="h-4 w-4" aria-hidden />}
        </IconButton>
      ) : null}
    </div>
  );
}
