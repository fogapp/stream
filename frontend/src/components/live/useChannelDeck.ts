import { useEffect, useLayoutEffect, useState, useSyncExternalStore } from "react";
import { ChannelDeck, type TuneBody } from "@/components/live/channelDeck";

/**
 * A Grid page's channels (ChannelDeck, which says what they do), held for as
 * long as the page is. The hook's own part is the timing: the effects below
 * run in this order, and a layout cleanup runs before React removes the page
 * where the passive ones run after it, which is what parkForGuide relies on.
 */
export function useChannelDeck(
  activeId: string | null,
  neighbours: string[],
  toGuide?: () => boolean,
  /** An airing and a place in it to tune a channel to when it first comes on screen, rather than live (a reload's way back). */
  resume?: (stationId: string) => TuneBody | null,
) {
  const [deck] = useState(() => new ChannelDeck(activeId));
  useSyncExternalStore(deck.subscribe, deck.getVersion);
  // Read when they're needed, as the page last committed them: written after
  // each commit, not during render, and before the effects below read them
  // (a layout effect runs ahead of the passive ones, and parkForGuide's
  // cleanup reads what the last commit left).
  useLayoutEffect(() => {
    deck.toGuide = toGuide;
    deck.resume = resume;
  });

  const wantedKey = [activeId, ...neighbours].filter((id): id is string => Boolean(id)).join(",");
  useEffect(() => deck.setLineup(activeId, wantedKey ? wantedKey.split(",") : []), [deck, activeId, wantedKey]);
  useEffect(() => deck.keepAtLive(), [deck]);
  useLayoutEffect(() => () => deck.parkForGuide(), [deck]);
  useEffect(() => () => deck.dispose(), [deck]);
  // After every render, not on a key: the slot's element may only just have been bound.
  useEffect(() => deck.timeSwitch(activeId));

  return { slots: deck.views(), bind: deck.bind, retune: deck.retune, retry: deck.retry, advance: deck.advance, activeElement: deck.elementOf(activeId) };
}
