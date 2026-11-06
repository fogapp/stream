import { formatDay } from "@/lib/format";
import type { HookFollow, HookSeason, HookShowAsked } from "@/types";

/**
 * Asking Hook from the palette (PROPOSAL §7.9): how a show's season reads
 * against what Stream already plays, and what the ask button says.
 */

/** Where a season stands: nothing left to ask for, or what asking would add. */
export interface SeasonStanding {
  label: string;
  hint: string;
  /** Everything is in Stream or already asked for. */
  settled: boolean;
}

export function seasonLabel(number: number): string {
  return number === 0 ? "Specials" : `Season ${number}`;
}

function episodes(count: number): string {
  return count === 1 ? "1 episode" : `${count} episodes`;
}

export function seasonStanding(season: HookSeason): SeasonStanding {
  const label = seasonLabel(season.number);
  const { episodes: total, aired, in_stream: held, requested } = season;
  if (total > 0 && held >= total) return { label, hint: "In Stream", settled: true };
  if (total > 0 && requested >= total) return { label, hint: "Requested", settled: true };
  if (aired === 0) {
    return { label, hint: season.next_air_date ? `Airs ${formatDay(season.next_air_date)}` : "Not aired yet", settled: false };
  }
  if (held > 0) return { label, hint: `${held} of ${total} in Stream`, settled: false };
  if (requested > 0) return { label, hint: `${requested} of ${total} requested`, settled: false };
  return { label, hint: episodes(total), settled: false };
}

export function hookFollow(follow: boolean, futureOnly: boolean): HookFollow | undefined {
  if (!follow) return undefined;
  return futureOnly ? "future" : "everything";
}

/** "Request 2 seasons and follow", "Request Specials", "Follow". */
export function askLabel(seasons: readonly number[], follow: boolean): string {
  if (seasons.length === 0) return follow ? "Follow" : "Request";
  const what = seasons.length === 1 ? seasonLabel(seasons[0]!) : `${seasons.length} seasons`;
  return `Request ${what}${follow ? " and follow" : ""}`;
}

/** What asking did, in one line under the button. */
export function askedSummary(asked: HookShowAsked, followed: boolean): string {
  const parts: string[] = [];
  if (asked.created > 0) parts.push(`Hook is looking for ${episodes(asked.created)}`);
  else if (asked.already > 0) parts.push("Those episodes were already requested");
  if (followed) parts.push(parts.length ? "and will keep the show coming" : "Hook will keep the show coming");
  return `${parts.join(" ")}.`;
}

/** A film's row once asked for: Hook's want status, as the person cares about it. */
export function wantLabel(status: string): string {
  return status === "unreleased" ? "Requested · not out yet" : "Requested";
}

/** TMDB's image URL Hook handed over, at the width it is drawn at. */
export function posterAt(url: string | null, width: 92 | 154 = 92): string | null {
  return url ? url.replace(/(image\.tmdb\.org\/t\/p\/)(w\d+|original)\//, `$1w${width}/`) : null;
}
