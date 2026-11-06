import type { PlayableKind } from "@/types/playback";

// Remote control (Api::V1::RemoteController#device_json).

export const REMOTE_COMMANDS = ["play", "pause", "resume", "stop", "seek", "tune"] as const;

export type RemoteCommandKind = (typeof REMOTE_COMMANDS)[number];

export interface RemoteDevice {
  id: string;
  name: string;
  browser: string;
  label: string | null;
  remote_control: boolean;
  listening: boolean;
  now_playing: { title: string; subtitle: string | null } | null;
}

export interface RemoteCommand {
  id: string;
  kind: RemoteCommandKind;
  payload: {
    /** play: a title, or a camera or web stream (PROPOSAL §7.8). */
    kind?: PlayableKind | "live_stream";
    id?: string;
    title?: string;
    start?: number;
    profile_id?: string;
    profile_token?: string;
    seconds?: number;
    by?: number;
    /** tune: a Grid channel. */
    number?: string;
    station_id?: string;
    name?: string;
  };
}
