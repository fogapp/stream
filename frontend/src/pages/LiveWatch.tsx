import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { ArrowLeft, CircleAlert, RotateCw } from "lucide-react";
import { ChannelBar } from "@/components/live/ChannelBar";
import { LivePlayer } from "@/components/live/LivePlayer";
import { StreamControls } from "@/components/live/StreamControls";
import { MiniGuide } from "@/components/live/MiniGuide";
import { OnNowPanel } from "@/components/live/OnNowPanel";
import { TuningCard } from "@/components/live/TuningCard";
import type { EndedVia } from "@/components/live/channelDeck";
import { useChannelDeck } from "@/components/live/useChannelDeck";
import { Button } from "@/components/ui/Button";
import { LoadingState } from "@/components/ui/PageState";
import { usePlayback } from "@/hooks/usePlayback";
import { cn } from "@/lib/cn";
import { notAShortcut } from "@/lib/keys";
import { adjacentStation, clockSkew, onAt } from "@/lib/live";
import { useNowGuide } from "@/lib/liveGuide";
import { livePlace } from "@/lib/livePlace";
import { liveHandoff } from "@/lib/liveHandoff";
import { fromTv } from "@/lib/tv";
import type { Airing, GuideStation } from "@/types";

/** How many of this page are mounted: one, or none once it's really left. */
let onScreen = 0;

/** A typed channel number is taken this long after the last digit. */
const ENTRY_MS = 1200;
/** Flipping past channels that aren't tuned ahead: only the one you stop on is tuned. */
const SETTLE_MS = 300;

/**
 * Whether an element has a picture to show yet: once it has, a seek or a
 * rebuffer doesn't take it away — only a new source (or an error) does,
 * so the controls stay put over a stumble.
 */
function usePicture(element: HTMLVideoElement | null): boolean {
  const [ready, setReady] = useState(false);
  useEffect(() => {
    if (!element) {
      setReady(false);
      return;
    }
    setReady(element.readyState >= 2 && !element.error);
    const shown = () => setReady((was) => (was || element.readyState >= 2) && !element.error);
    const gone = () => setReady(false);
    const events = ["loadeddata", "playing", "seeked", "canplay"] as const;
    for (const name of events) element.addEventListener(name, shown);
    element.addEventListener("emptied", gone);
    element.addEventListener("error", gone);
    return () => {
      for (const name of events) element.removeEventListener(name, shown);
      element.removeEventListener("emptied", gone);
      element.removeEventListener("error", gone);
    };
  }, [element]);
  return ready;
}

/**
 * A Grid channel, full screen (PROPOSAL §7.7). The channel on screen and
 * its neighbours — up, down, and the last one watched — are each tuned and
 * buffered at live, so changing channel is showing another picture. The
 * banner answers a key at once; flipping quickly past channels only tunes
 * the one you stop on. When a program ends the next follows (as far behind
 * live as the viewer was), a gap shows what's next, and the guide slides up
 * over the picture.
 */
export function LiveWatch() {
  const { number = "" } = useParams();
  const navigate = useNavigate();
  const guide = useNowGuide();
  const { close, registerLiveMain } = usePlayback();
  const [shown, setShown] = useState(number);
  const [last, setLast] = useState<string | null>(null);
  const [entry, setEntry] = useState("");
  const [guideOpen, setGuideOpen] = useState(false);
  // What's on now, down the side: one of it and the guide at a time.
  const [nowOpen, setNowOpen] = useState(false);
  const openGuide = useCallback(() => {
    setNowOpen(false);
    setGuideOpen(true);
  }, []);
  const toggleNow = useCallback(() => setNowOpen((open) => !open), []);
  const [now, setNow] = useState(Date.now());
  const settle = useRef<number | undefined>(undefined);
  // Back to the guide it came from: the TV's, or the desktop's.
  const guidePath = fromTv() ? "/tv/live" : "/live";

  const stations = useMemo(() => guide.data?.stations ?? [], [guide.data]);
  const timeZone = guide.data?.time_zone ?? "UTC";
  const byNumber = useCallback((wanted: string | null) => stations.find((station) => station.number === wanted) ?? null, [stations]);
  const station = byNumber(number);
  const shownStation = byNumber(shown) ?? station;
  const up = station ? adjacentStation(stations, number, 1) : null;
  const down = station ? adjacentStation(stations, number, -1) : null;
  const neighbours = [...new Set([up?.id, down?.id, byNumber(last)?.id].filter((id): id is string => Boolean(id) && id !== station?.id))];
  // A reload of the page comes back to where the viewer was on this channel,
  // behind live: a place is only kept for the channel on screen, and only
  // until it's changed or left (livePlace).
  // Swapped here from the inset, it carries on from there instead.
  const resume = useCallback((stationId: string) => (liveHandoff.has(stationId) || liveHandoff.isSwapping(stationId) ? null : livePlace.resume(stationId, Date.now())), []);
  // Read as the page goes: the Back button, Escape and the browser's own Back all end up there.
  const deck = useChannelDeck(station?.id ?? null, neighbours, () => window.location.pathname === guidePath, resume);
  const active = deck.slots.find((slot) => slot.stationId === station?.id) ?? null;
  const skew = active?.skew ?? (guide.data ? clockSkew(guide.data.now, guide.dataUpdatedAt) : 0);
  const picture = usePicture(deck.activeElement);

  // A VOD player in the corner stops: this is the screen now.
  useEffect(() => close(), [close]);
  // The main picture, for picture in picture: what an inset is over, and what a swap trades.
  const stationName = station?.name ?? null;
  useEffect(() => {
    if (station?.id && stationName) return registerLiveMain({ kind: "station", stationId: station.id, number, title: stationName });
  }, [station?.id, number, stationName, registerLiveMain]);
  // Browser full screen on the whole page (with an inset up) ends with this page — unless it's swapping into the inset.
  useEffect(
    () => () => {
      if (document.fullscreenElement === document.documentElement && !liveHandoff.isSwapping()) void document.exitFullscreen().catch(() => undefined);
    },
    [],
  );
  // The place kept for a reload is this channel's, and goes when the page is left.
  const stationId = station?.id ?? null;
  useEffect(() => {
    if (stationId) livePlace.watch(stationId);
  }, [stationId]);
  useEffect(() => {
    onScreen += 1;
    return () => {
      onScreen -= 1;
      // Not for Strict Mode's rehearsal, which mounts again at once.
      window.setTimeout(() => {
        if (onScreen === 0) livePlace.leave();
      }, 0);
    };
  }, []);
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, []);

  // The channel in the address is the one on screen; the one before it is Last.
  const committed = useRef(number);
  useEffect(() => {
    if (committed.current !== number) setLast(committed.current);
    committed.current = number;
    setShown(number);
  }, [number]);

  const commit = useCallback((target: string) => navigate(`/live/${encodeURIComponent(target)}`, { replace: true }), [navigate]);
  // Read through a ref: the slots change every render, and timers mustn't restart with them.
  const slotsRef = useRef(deck.slots);
  slotsRef.current = deck.slots;
  const choose = useCallback(
    (target: GuideStation | null) => {
      if (!target) return;
      window.clearTimeout(settle.current);
      setShown(target.number);
      const ready = slotsRef.current.some((slot) => slot.stationId === target.id && slot.state === "ready");
      if (ready) commit(target.number);
      else settle.current = window.setTimeout(() => commit(target.number), SETTLE_MS);
    },
    [commit],
  );
  const flip = useCallback((step: 1 | -1) => choose(adjacentStation(stations, shown, step)), [choose, stations, shown]);
  useEffect(() => () => window.clearTimeout(settle.current), []);

  // Channel keys: up/down, typed numbers, Last, and the guide.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (notAShortcut(event)) return;
      if (guideOpen) return;
      if (event.key === "ArrowUp" || event.key === "PageUp") flip(1);
      else if (event.key === "ArrowDown" || event.key === "PageDown") flip(-1);
      else if (/^[0-9.]$/.test(event.key)) setEntry((typed) => (typed + event.key).slice(0, 7));
      else if (event.key === "Enter" && entry) {
        choose(byNumber(entry));
        setEntry("");
      } else if (event.key === "Backspace" || event.key === "-") choose(byNumber(last));
      else if (event.key === "g") openGuide();
      else if (event.key === "Escape" && nowOpen) setNowOpen(false);
      else if (event.key === "Escape" || event.key === "BrowserBack") navigate(guidePath);
      else return;
      event.preventDefault();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [flip, entry, choose, byNumber, last, guideOpen, navigate, guidePath, nowOpen, openGuide]);
  useEffect(() => {
    if (!entry) return;
    const timer = window.setTimeout(() => {
      const target = byNumber(entry);
      if (target) choose(target);
      setEntry("");
    }, ENTRY_MS);
    return () => window.clearTimeout(timer);
  }, [entry, byNumber, choose]);

  const serverNow = now + skew;
  const { current, next } = shownStation ? onAt(shownStation, serverNow) : { current: null, next: null };
  const playing: Airing | null = station?.airings.find((airing) => airing.id === active?.session?.live?.airing_id) ?? null;
  const upcoming = playing ? (station?.airings.find((airing) => Date.parse(airing.starts_at) >= Date.parse(playing.ends_at) - 1000) ?? null) : next;

  // On to the next program, as far behind live as the viewer was: the deck
  // has it tuned ahead, or asks for it — or shows the slate until it starts.
  const { advance, retune } = deck;
  const onEnded = useCallback((lag: number, via: EndedVia) => advance(lag, via), [advance]);

  // A game on a channel is a stream with a slot: when the slot ends, on to
  // what follows, as for any program.
  const slotEnd = active?.session?.live_stream ? active.session.live?.ends_at : undefined;
  const activeSkew = active?.skew ?? 0;
  useEffect(() => {
    if (!slotEnd) return;
    const timer = window.setTimeout(() => advance(0, "ended"), Math.max(Date.parse(slotEnd) - (Date.now() + activeSkew), 0));
    return () => window.clearTimeout(timer);
  }, [slotEnd, activeSkew, advance]);

  // Restart: the program's first part, when it airs in parts (behind live).
  const onRestart = useCallback(() => {
    if (!station || !playing) return;
    const earlier = station.airings.filter((airing) => airing.playable_id === playing.playable_id && Date.parse(airing.starts_at) <= Date.parse(playing.starts_at));
    const first = earlier.find((airing) => airing.media_start === 0) ?? playing;
    retune({ airing_id: first.id, start: 0 });
  }, [station, playing, retune]);

  const entryOverlay = entry ? (
    <div className="pointer-events-none absolute right-6 top-6 z-30 rounded-[var(--radius-card)] bg-surface/90 px-4 py-2 font-mono text-4xl tabular-nums" aria-live="polite">
      {entry}
      <span className="animate-pulse">_</span>
    </div>
  ) : null;

  if (guide.isError || (guide.data && !station)) {
    return (
      <div data-theme="dark" className="fixed inset-0 z-50 flex items-center justify-center bg-background p-6 text-foreground">
        <div className="max-w-md space-y-4 text-center">
          <CircleAlert className="mx-auto h-8 w-8 text-warning" aria-hidden />
          <p>{guide.isError ? "The guide couldn't be loaded." : `There's no channel ${number}.`}</p>
          <Button variant="secondary" onClick={() => navigate(guidePath)}>
            <ArrowLeft className="h-4 w-4" aria-hidden />
            Guide
          </Button>
        </div>
      </div>
    );
  }
  if (!guide.data) {
    return (
      <div data-theme="dark" className="fixed inset-0 z-50 flex items-center justify-center bg-background">
        <LoadingState label="Tuning…" />
      </div>
    );
  }

  const switching = shown !== number;
  const message =
    active?.state === "failed" ? "This channel couldn't be tuned." : active?.state === "unavailable" ? "This channel can't play here right now." : undefined;
  const showCard = switching || !picture || active?.state !== "ready";

  return (
    <div data-theme="dark" className="fixed inset-0 z-50 overflow-hidden bg-background text-foreground">
      {deck.slots.flatMap((slot) =>
        slot.videos.map((key) => (
          <video
            key={`${slot.stationId}:${key}`}
            ref={deck.bind(slot.stationId, key)}
            className={cn("absolute inset-0 h-full w-full", slot.stationId === station?.id && key === slot.front && !switching ? "visible" : "invisible")}
            playsInline
            preload="auto"
            data-station={slot.stationId}
            data-state={key === slot.front ? slot.state : "next"}
            data-airing={key === slot.front ? slot.session?.live?.airing_id : undefined}
          />
        )),
      )}
      {showCard ? (
        <>
          <TuningCard
            station={shownStation}
            airing={active?.state === "gap" && !switching ? null : current}
            next={next}
            timeZone={timeZone}
            now={serverNow}
            message={switching ? undefined : message}
            action={
              !switching && active?.state === "failed" ? (
                <Button variant="secondary" onClick={deck.retry}>
                  <RotateCw className="h-4 w-4" aria-hidden />
                  Try again
                </Button>
              ) : null
            }
          />
          {/* Without a picture there's no player: the channel can still be changed. */}
          <div className="absolute inset-x-0 top-0 z-10">
            <ChannelBar onBack={() => navigate(guidePath)} onChannel={flip} onGuide={openGuide} onNow={toggleNow} nowOpen={nowOpen} />
          </div>
        </>
      ) : null}
      {!showCard && active?.session?.live_stream && deck.activeElement ? (
        <StreamControls
          key={active.session.id}
          video={deck.activeElement}
          session={active.session}
          keys={!guideOpen}
          onBack={() => navigate(guidePath)}
          playing={{ kind: "station", stationId: active.stationId, number, title: shownStation?.name ?? number }}
          top={<ChannelBar onBack={() => navigate(guidePath)} onChannel={flip} onGuide={openGuide} onNow={toggleNow} nowOpen={nowOpen} />}
        />
      ) : null}
      {!showCard && active?.session && !active.session.live_stream && deck.activeElement ? (
        <LivePlayer
          key={active.session.id}
          video={deck.activeElement}
          session={active.session}
          airing={playing}
          next={upcoming}
          timeZone={timeZone}
          skew={active.skew}
          keys={!guideOpen}
          onEnded={onEnded}
          onRestart={onRestart}
          onBack={() => navigate(guidePath)}
          onChannel={flip}
          onGuide={openGuide}
          onNow={toggleNow}
          nowOpen={nowOpen}
          bannerKey={active.session.id}
        />
      ) : null}
      {guideOpen && guide.data ? (
        <MiniGuide
          guide={guide.data}
          stationId={station?.id ?? null}
          now={serverNow}
          onChoose={(target, airing) => {
            if (Date.parse(airing.starts_at) <= serverNow && Date.parse(airing.ends_at) > serverNow) {
              setGuideOpen(false);
              choose(target);
            }
          }}
          onClose={() => setGuideOpen(false)}
        />
      ) : null}
      {/* Outside the fading controls: open, it stays until closed. */}
      {nowOpen && guide.data ? (
        <OnNowPanel guide={guide.data} stationId={shownStation?.id ?? null} now={serverNow} onChoose={choose} onClose={() => setNowOpen(false)} />
      ) : null}
      {entryOverlay}
    </div>
  );
}
