import { useEffect, useEffectEvent, useRef } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useLocation, useNavigate } from "react-router-dom";
import { api } from "@/api/client";
import { usePlayback } from "@/hooks/usePlayback";
import { useProfile } from "@/hooks/useProfile";
import { keys } from "@/lib/queryKeys";
import { toast } from "@/components/ui/Toast";
import { fromTv } from "@/lib/tv";
import type { RemoteCommand, RemoteDevice } from "@/types";

/** Opened as a TV this session, even while it's showing the player. */
const isTv = (pathname: string) => pathname.startsWith("/tv") || fromTv();

/** How often a screen that can be played to asks for commands. */
const POLL_MS = 2_000;

/**
 * Being played to (PROPOSAL §11 Phase 6): a browser that allows it — every
 * TV on /tv does — asks every couple of seconds whether anyone (the app on
 * a phone, or an agent over MCP) wants it to play, pause, seek or stop.
 * Renders nothing.
 */
export function RemoteListener() {
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const { pathname } = useLocation();
  const { profile, adopt } = useProfile();
  const playback = usePlayback();
  const tv = isTv(pathname);
  const device = useQuery({ queryKey: keys.remote.thisDevice(), queryFn: ({ signal }) => api.get<RemoteDevice>("/remote/this_device", { signal }) });
  const handled = useRef(new Set<string>());

  // A TV is there to be played to.
  const enabled = device.data?.remote_control ?? false;
  useEffect(() => {
    if (tv && device.data && !device.data.remote_control) {
      void api
        .patch<RemoteDevice>("/remote/this_device", { remote_control: true })
        .then((updated) => queryClient.setQueryData(keys.remote.thisDevice(), updated))
        .catch(() => undefined);
    }
  }, [tv, device.data, queryClient]);

  // What a command does, with whatever the page is now: the poll below
  // runs from when the screen allows it, not again on every navigation.
  const run = useEffectEvent((command: RemoteCommand) => {
    if (handled.current.has(command.id)) return;
    handled.current.add(command.id);
    // Grid holds neighbouring channels in hidden videos: the one on screen.
    const video = document.querySelector<HTMLVideoElement>("video.visible") ?? document.querySelector("video");
    switch (command.kind) {
      case "play": {
        const { kind, id, title, start, profile_id: profileId, profile_token: token } = command.payload;
        if (!kind || !id) return;
        if (profileId && token && profileId !== profile?.id) adopt(token);
        toast.info(`Playing ${title ?? "something"}, sent from another screen.`);
        // A camera or web stream (PROPOSAL §7.8) has its own player.
        navigate(kind === "live_stream" ? `/stream/${id}` : `/watch/${kind}/${id}${start === 0 ? "?from=start" : ""}`);
        return;
      }
      case "tune": {
        const { number, name, profile_id: profileId, profile_token: token } = command.payload;
        if (!number) return;
        if (profileId && token && profileId !== profile?.id) adopt(token);
        toast.info(`Channel ${number}${name ? ` ${name}` : ""}, sent from another screen.`);
        navigate(`/live/${encodeURIComponent(number)}`);
        return;
      }
      case "pause":
        video?.pause();
        return;
      case "resume":
        void video?.play().catch(() => undefined);
        return;
      case "seek":
        if (!video) return;
        if (command.payload.seconds !== undefined) video.currentTime = command.payload.seconds;
        else if (command.payload.by !== undefined) video.currentTime = Math.max(0, video.currentTime + command.payload.by);
        return;
      case "stop":
        playback.close();
        if (pathname.startsWith("/watch")) navigate(tv ? "/tv" : "/");
        return;
    }
  });

  useEffect(() => {
    if (!enabled) return;
    let live = true;
    const poll = async () => {
      try {
        const commands = await api.get<RemoteCommand[]>("/remote/commands");
        if (live) for (const command of commands) run(command);
      } catch {
        // Offline or restarting: ask again next time.
      }
    };
    const timer = window.setInterval(() => void poll(), POLL_MS);
    void poll();
    return () => {
      live = false;
      window.clearInterval(timer);
    };
  }, [enabled]);

  return null;
}
