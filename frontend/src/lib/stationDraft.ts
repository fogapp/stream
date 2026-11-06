import type { StationBlock, StationConfig, StationFiller, StationPresetDraft } from "@/types";

/** A channel as its editor holds it (PROPOSAL §7.7), and how one starts. */
export interface StationDraft {
  number: string;
  name: string;
  call_sign: string;
  snap_minutes: number;
  no_repeat_days: number;
  filler: StationFiller;
  filler_channel_ids: string[];
  breaks: boolean;
  blocks: StationBlock[];
  /** A camera or web stream it shows instead of its programming (PROPOSAL §7.8). */
  live_stream_id: string | null;
  /** MLB clubs whose games it airs whenever they play, the first listed first. */
  mlb_team_ids: number[];
}

export const EMPTY_BASE: StationBlock = {
  layer: "base",
  name: null,
  days: 127,
  start_minute: null,
  end_minute: null,
  starts_on: null,
  ends_on: null,
  source: { kinds: ["episode", "movie"] },
  ordering: "shuffle",
  marathon_length: 3,
  loops: true,
};

export function draftFrom(station: StationConfig | null): StationDraft {
  if (!station) return { number: "", name: "", call_sign: "", snap_minutes: 0, no_repeat_days: 3, filler: "slate", filler_channel_ids: [], breaks: false, blocks: [EMPTY_BASE], live_stream_id: null, mlb_team_ids: [] };
  return {
    number: station.number,
    name: station.name,
    call_sign: station.call_sign ?? "",
    snap_minutes: station.snap_minutes,
    no_repeat_days: station.no_repeat_days,
    filler: station.filler,
    filler_channel_ids: station.filler_channel_ids,
    breaks: station.breaks,
    blocks: station.blocks.some((block) => block.layer === "base") ? station.blocks : [EMPTY_BASE, ...station.blocks],
    live_stream_id: station.live_stream_id,
    mlb_team_ids: station.mlb_team_ids,
  };
}


/** A new timed block, as the clock or the Add buttons make one. */
export function newBlock(layer: "daypart" | "appointment" | "special", days: number, start: number, end: number): StationBlock {
  return {
    layer,
    name: null,
    days,
    start_minute: start,
    end_minute: end,
    starts_on: null,
    ends_on: null,
    source: { kinds: ["episode", "movie"] },
    ordering: layer === "appointment" ? "sequential" : "shuffle",
    marathon_length: 3,
    loops: true,
  };
}

/** A preset as the editor's starting point. */
export function draftFromPreset(preset: StationPresetDraft): StationDraft {
  return {
    number: preset.number,
    name: preset.name,
    call_sign: preset.call_sign ?? "",
    snap_minutes: preset.snap_minutes,
    no_repeat_days: preset.no_repeat_days,
    filler: preset.filler,
    filler_channel_ids: preset.filler_channel_ids,
    breaks: false,
    blocks: preset.blocks,
    live_stream_id: null,
    mlb_team_ids: [],
  };
}
