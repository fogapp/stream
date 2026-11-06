import { useCallback, useEffect, useMemo, useRef, useState, type DragEvent, type KeyboardEvent, type MouseEvent, type PointerEvent } from "react";

/**
 * Where the mini-player sits and how big it is. Position is a fraction of
 * the room left over on each axis (0 = left/top, 1 = right/bottom), so a
 * player docked in a corner stays in that corner when the window changes.
 */
export interface MiniFrame {
  x: number;
  y: number;
  width: number;
}

export interface Viewport {
  width: number;
  height: number;
}

export interface Box {
  left: number;
  top: number;
  width: number;
  height: number;
}

/**
 * Where the inset is kept: inside the main picture. On a page that scrolls
 * (a video in its page's slot) in page coordinates, placed absolutely so it
 * scrolls along; else in the window's, placed fixed.
 */
export interface InsetArea {
  box: Box;
  page: boolean;
}

/** The corner a resize drags; the opposite one stays put. */
export type Corner = "top-left" | "top-right" | "bottom-left" | "bottom-right";

export const MINI_FRAME_DEFAULT: MiniFrame = { x: 1, y: 1, width: 320 };
/** The inset (picture in picture) starts top right, clear of the controls along the bottom. */
const PIP_FRAME_DEFAULT: MiniFrame = { x: 1, y: 0, width: 320 };

/** The mini-player in the corner, or the inset over the picture: each remembers its own place. */
export type FramePlace = "mini" | "pip";
const PLACES: Record<FramePlace, { key: string; fallback: MiniFrame }> = {
  mini: { key: "stream_mini_player", fallback: MINI_FRAME_DEFAULT },
  pip: { key: "stream_pip_frame", fallback: PIP_FRAME_DEFAULT },
};
const ASPECT = 16 / 9;
const MARGIN = 16;
const MIN_WIDTH = 200;

function clamp(value: number, min: number, max: number) {
  return Math.min(Math.max(value, min), max);
}

function maxWidth(viewport: Viewport) {
  return Math.max(0, Math.min(viewport.width - 2 * MARGIN, (viewport.height - 2 * MARGIN) * ASPECT));
}

/** The frame as pixels on this screen, always wholly on it. */
export function frameBox(frame: MiniFrame, viewport: Viewport): Box {
  const largest = maxWidth(viewport);
  const width = clamp(frame.width, Math.min(MIN_WIDTH, largest), largest);
  const height = width / ASPECT;
  return {
    left: MARGIN + clamp(frame.x, 0, 1) * Math.max(0, viewport.width - 2 * MARGIN - width),
    top: MARGIN + clamp(frame.y, 0, 1) * Math.max(0, viewport.height - 2 * MARGIN - height),
    width,
    height,
  };
}

/** A box placed by hand, back to a frame (and so clamped onto the screen). */
export function boxFrame(left: number, top: number, width: number, viewport: Viewport): MiniFrame {
  const largest = maxWidth(viewport);
  const fitted = clamp(width, Math.min(MIN_WIDTH, largest), largest);
  const roomX = viewport.width - 2 * MARGIN - fitted;
  const roomY = viewport.height - 2 * MARGIN - fitted / ASPECT;
  return {
    x: roomX > 0 ? clamp((left - MARGIN) / roomX, 0, 1) : 0,
    y: roomY > 0 ? clamp((top - MARGIN) / roomY, 0, 1) : 0,
    width: fitted,
  };
}

/** Dragging one corner by (dx, dy): 16:9 kept, the opposite corner fixed. */
export function resizeBox(start: Box, corner: Corner, dx: number, dy: number, viewport: Viewport): MiniFrame {
  const sx = corner.endsWith("left") ? -1 : 1;
  const sy = corner.startsWith("top") ? -1 : 1;
  const largest = maxWidth(viewport);
  // Whichever way the pointer went further decides, so a corner shrinks
  // the player as readily as it grows it.
  const fromX = start.width + sx * dx;
  const fromY = (start.height + sy * dy) * ASPECT;
  const wanted = Math.abs(fromX - start.width) >= Math.abs(fromY - start.width) ? fromX : fromY;
  const width = clamp(wanted, Math.min(MIN_WIDTH, largest), largest);
  const height = width / ASPECT;
  const left = sx < 0 ? start.left + start.width - width : start.left;
  const top = sy < 0 ? start.top + start.height - height : start.top;
  return boxFrame(left, top, width, viewport);
}

function stored(place: FramePlace): MiniFrame {
  try {
    const parsed = JSON.parse(localStorage.getItem(PLACES[place].key) ?? "null") as Partial<MiniFrame> | null;
    if (parsed && [parsed.x, parsed.y, parsed.width].every((value) => typeof value === "number" && Number.isFinite(value))) {
      return parsed as MiniFrame;
    }
  } catch {
    // A nicety.
  }
  return PLACES[place].fallback;
}

function remember(place: FramePlace, frame: MiniFrame) {
  try {
    localStorage.setItem(PLACES[place].key, JSON.stringify(frame));
  } catch {
    // A nicety.
  }
}

function viewportNow(): Viewport {
  return { width: window.innerWidth, height: window.innerHeight };
}

/** Moves more than this and a press is a drag, not a click. */
const DRAG_SLOP = 4;
const KEY_STEP = 24;

/**
 * Drag the mini-player anywhere, resize it from any corner, and move or
 * resize it from the keyboard (arrows move, Shift+arrows resize). Where it
 * was left is remembered in this browser, for the corner and the inset apart.
 * Within the window, or within `bounds` (the main picture the inset is kept
 * inside, in the same coordinates the returned box is placed in).
 */
export function useMiniFrame(place: FramePlace = "mini", bounds: Box | null = null) {
  const [frame, setFrame] = useState<MiniFrame>(() => stored(place));
  const [windowSize, setViewport] = useState<Viewport>(viewportNow);
  const boundsWidth = bounds?.width;
  const boundsHeight = bounds?.height;
  const viewport = useMemo(
    () => (boundsWidth !== undefined && boundsHeight !== undefined ? { width: boundsWidth, height: boundsHeight } : windowSize),
    [boundsWidth, boundsHeight, windowSize],
  );
  const [dragging, setDragging] = useState(false);
  const gesture = useRef<{ kind: "move" | Corner; x: number; y: number; start: Box; moved: boolean } | null>(null);
  /** A drag just ended: swallow the click that follows it. */
  const dragged = useRef(false);
  // Within the bounds; placed where they are.
  const local = frameBox(frame, viewport);
  const box = bounds ? { ...local, left: local.left + bounds.left, top: local.top + bounds.top } : local;

  useEffect(() => {
    const onResize = () => setViewport(viewportNow());
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

  const begin = useCallback(
    (kind: "move" | Corner) => (event: PointerEvent<HTMLElement>) => {
      if (event.button !== 0) return;
      // Buttons inside the player keep their clicks; its body and the Move
      // handle drag.
      const target = event.target as HTMLElement;
      if (kind === "move" && target.closest("button, a, input") && !target.closest("[data-drag-handle]")) return;
      event.stopPropagation();
      event.currentTarget.setPointerCapture(event.pointerId);
      gesture.current = { kind, x: event.clientX, y: event.clientY, start: local, moved: false };
      dragged.current = false;
    },
    [local],
  );

  const onPointerMove = useCallback(
    (event: PointerEvent<HTMLElement>) => {
      const active = gesture.current;
      if (!active) return;
      const dx = event.clientX - active.x;
      const dy = event.clientY - active.y;
      if (!active.moved && Math.hypot(dx, dy) < DRAG_SLOP) return;
      if (!active.moved) {
        active.moved = true;
        setDragging(true);
      }
      const next =
        active.kind === "move"
          ? boxFrame(active.start.left + dx, active.start.top + dy, active.start.width, viewport)
          : resizeBox(active.start, active.kind, dx, dy, viewport);
      setFrame(next);
    },
    [viewport],
  );

  const end = useCallback(() => {
    const active = gesture.current;
    gesture.current = null;
    if (!active?.moved) return;
    dragged.current = true;
    setDragging(false);
    setFrame((current) => {
      remember(place, current);
      return current;
    });
  }, [place]);

  const onClickCapture = useCallback((event: MouseEvent) => {
    if (!dragged.current) return;
    dragged.current = false;
    event.stopPropagation();
    event.preventDefault();
  }, []);

  const onKeyDown = useCallback(
    (event: KeyboardEvent<HTMLElement>) => {
      const step = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[event.key];
      if (!step) return;
      event.preventDefault();
      const [sx, sy] = step as [number, number];
      const next = event.shiftKey
        ? resizeBox(local, "top-left", -KEY_STEP * (sx || -sy), 0, viewport)
        : boxFrame(local.left + sx * KEY_STEP, local.top + sy * KEY_STEP, local.width, viewport);
      setFrame(next);
      remember(place, next);
    },
    [local, viewport, place],
  );

  // A native drag (of the video itself, say) would take the pointer away.
  const onDragStart = useCallback((event: DragEvent) => event.preventDefault(), []);

  const handlers = { onPointerMove, onPointerUp: end, onPointerCancel: end };
  return {
    box,
    dragging,
    frameProps: { onPointerDown: begin("move"), onClickCapture, onDragStart, ...handlers },
    // Captured by the handle, its moves bubble up to the frame's handlers.
    cornerProps: (corner: Corner) => ({ onPointerDown: begin(corner) }),
    onKeyDown,
  };
}
