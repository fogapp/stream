import { useEffect, type RefObject } from "react";

type Direction = "left" | "right" | "up" | "down";
const KEYS: Record<string, Direction> = { ArrowLeft: "left", ArrowRight: "right", ArrowUp: "up", ArrowDown: "down" };

/**
 * A TV remote's arrows move focus to the nearest focusable thing in that
 * direction (PROPOSAL §7.4 — the 10-foot layout), within the container.
 * Focusables are marked data-tv; Enter presses them like any button or
 * link. Focus starts on data-tv-autofocus, else the page's first.
 */
export function useSpatialNav(container: RefObject<HTMLElement | null>, ready: boolean) {
  useEffect(() => {
    const root = container.current;
    if (!root || !ready) return;
    const focusables = () => Array.from(root.querySelectorAll<HTMLElement>("[data-tv]")).filter((element) => element.offsetParent !== null);
    // Where focus starts: the page's main action, else the first thing in
    // the page itself rather than the header, else anything.
    if (!root.contains(document.activeElement) || document.activeElement === root) {
      const start =
        root.querySelector<HTMLElement>("[data-tv-autofocus]") ?? root.querySelector<HTMLElement>("main [data-tv]") ?? focusables()[0];
      start?.focus();
    }

    const onKey = (event: KeyboardEvent) => {
      const direction = KEYS[event.key];
      if (!direction || event.defaultPrevented) return;
      // A grid moves its own focus (the Grid guide): only where it
      // doesn't — past its edge — do the arrows leave it.
      if (event.target instanceof Element && event.target.closest("[role=grid]")) {
        window.setTimeout(() => {
          if (!event.defaultPrevented) move(event, direction);
        });
        return;
      }
      move(event, direction);
    };

    const move = (event: KeyboardEvent, direction: Direction) => {
      // In a text box, left and right move the caret.
      if ((direction === "left" || direction === "right") && event.target instanceof HTMLInputElement && event.target.value !== "") return;
      const current = document.activeElement instanceof HTMLElement && root.contains(document.activeElement) ? document.activeElement : null;
      const candidates = focusables();
      if (!current) {
        candidates[0]?.focus();
        event.preventDefault();
        return;
      }
      const from = current.getBoundingClientRect();
      const fromX = from.left + from.width / 2;
      const fromY = from.top + from.height / 2;
      let best: HTMLElement | null = null;
      let bestScore = Infinity;
      for (const candidate of candidates) {
        if (candidate === current) continue;
        const to = candidate.getBoundingClientRect();
        const dx = to.left + to.width / 2 - fromX;
        const dy = to.top + to.height / 2 - fromY;
        const along = direction === "left" ? -dx : direction === "right" ? dx : direction === "up" ? -dy : dy;
        if (along <= 1) continue;
        const across = direction === "left" || direction === "right" ? Math.abs(dy) : Math.abs(dx);
        // Straight ahead beats diagonal: the sideways distance counts double.
        const score = along + across * 2;
        if (score < bestScore) {
          bestScore = score;
          best = candidate;
        }
      }
      if (best) {
        best.focus();
        best.scrollIntoView({ block: "nearest", inline: "center", behavior: "smooth" });
      }
      event.preventDefault();
    };
    root.addEventListener("keydown", onKey);
    return () => root.removeEventListener("keydown", onKey);
  }, [container, ready]);
}
