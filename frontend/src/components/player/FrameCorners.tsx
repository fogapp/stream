import type { PointerEvent } from "react";
import { cn } from "@/lib/cn";
import type { Corner } from "@/components/player/miniFrame";

/** The resize handles: pointer-only; Shift+arrows on the focused frame is the keyboard's way. */
const CORNERS: { corner: Corner; className: string }[] = [
  { corner: "top-left", className: "left-0 top-0 cursor-nwse-resize" },
  { corner: "top-right", className: "right-0 top-0 cursor-nesw-resize" },
  { corner: "bottom-left", className: "bottom-0 left-0 cursor-nesw-resize" },
  { corner: "bottom-right", className: "bottom-0 right-0 cursor-nwse-resize" },
];

/** A floating frame's buttons: a dark disc each, so they read over any picture. */
export const MINI_BUTTON = "rounded-full bg-background/70 text-foreground shadow-md backdrop-blur-sm hover:bg-background/90 hover:text-foreground";

/** The four corners a floating frame (the mini-player, the inset) is resized from. */
export function FrameCorners({ cornerProps }: { cornerProps: (corner: Corner) => { onPointerDown: (event: PointerEvent<HTMLElement>) => void } }) {
  return CORNERS.map(({ corner, className }) => <div key={corner} aria-hidden className={cn("absolute z-10 h-4 w-4", className)} {...cornerProps(corner)} />);
}
