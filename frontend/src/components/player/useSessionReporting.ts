import { useCallback, useEffect, useRef, type RefObject } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { captureStill } from "@/lib/lastWatched";
import { beaconProgress, postEvents, postProgress, type PlaybackEventReport } from "@/lib/playbackSession";
import { refreshWatched } from "@/lib/watched";

const REPORT_EVERY_MS = 10_000;

export type PlayerEvent = PlaybackEventReport & { kind: "startup" | "seek" | "stall" | "recovery" | "error" };

/** What a play went through, held until there's a moment to send it. */
export function useSessionEvents(url: string) {
  const events = useRef<PlayerEvent[]>([]);
  const note = useCallback((event: PlayerEvent) => {
    events.current.push(event);
  }, []);
  const flushEvents = useCallback(() => {
    if (events.current.length === 0) return;
    postEvents(url, events.current.splice(0));
  }, [url]);
  return { note, flushEvents };
}

/**
 * Where a play has got to, so the next device can resume there: while
 * playing, every ten seconds, and a final report however it's left. Its
 * cleanup is that final report, so this is called after the effect that
 * attaches the source — the same order of leaving, whatever else moves.
 */
export function useSessionReporting({
  video,
  url,
  playing,
  flushEvents,
  onReport,
}: {
  video: RefObject<HTMLVideoElement | null>;
  url: string;
  playing: boolean;
  flushEvents: () => void;
  /** Each report, with the frame on screen when it's stopping or leaving. */
  onReport?: (position: number, duration: number, still: string | null) => void;
}) {
  // Held in a ref: a new callback each render mustn't re-run what depends on report.
  const onReportRef = useRef(onReport);
  useEffect(() => {
    onReportRef.current = onReport;
  }, [onReport]);

  // The first report that finds it watched refreshes what it moves —
  // Continue watching on the page under the corner, Up next, badges — at
  // once, not on the next visit.
  const queryClient = useQueryClient();
  const completed = useRef(false);
  useEffect(() => {
    completed.current = false;
  }, [url]);

  const report = useCallback(
    (ended = false, leaving = false) => {
      const element = video.current;
      if (!element || !Number.isFinite(element.currentTime)) return;
      // The frame on screen, for the corner card after a reload: drawn only
      // when stopping or leaving, not on every timed report while playing.
      const still = ended || element.paused ? captureStill(element) : null;
      onReportRef.current?.(element.currentTime, Number.isFinite(element.duration) ? element.duration : 0, still);
      const body = { position: element.currentTime, ended };
      // A beacon survives the page closing; a fetch might not.
      if (leaving && beaconProgress(url, body)) return;
      void postProgress<{ completed?: boolean }>(url, body).then((state) => {
        if (!state?.completed || completed.current) return;
        completed.current = true;
        refreshWatched(queryClient);
      });
    },
    [video, url, queryClient],
  );

  useEffect(() => {
    if (!playing) return;
    const timer = window.setInterval(() => {
      report();
      flushEvents();
    }, REPORT_EVERY_MS);
    return () => window.clearInterval(timer);
  }, [playing, report, flushEvents]);
  useEffect(() => {
    const onHide = () => {
      flushEvents();
      report(true, true);
    };
    window.addEventListener("pagehide", onHide);
    return () => {
      window.removeEventListener("pagehide", onHide);
      onHide();
    };
  }, [report, flushEvents]);

  return report;
}
