import { useRef, type PointerEvent } from "react";
import { cn } from "@/lib/cn";
import type { LetterStart } from "@/types";

const ALPHABET = ["#", ..."ABCDEFGHIJKLMNOPQRSTUVWXYZ"];

/**
 * The alphabet down the right of an A–Z poster wall: a letter jumps to its
 * first title. A finger can run down it as on a phone's contacts; letters
 * no title files under are there but dimmed, so the rail never shifts.
 */
export function AlphabetRail({ starts, onJump }: { starts: LetterStart[]; onJump: (index: number) => void }) {
  const at = new Map(starts.map((start) => [start.letter, start.index]));
  const last = useRef<string | null>(null);

  function jump(letter: string | undefined) {
    const index = letter === undefined ? undefined : at.get(letter);
    if (letter === undefined || index === undefined || letter === last.current) return;
    last.current = letter;
    onJump(index);
  }

  function letterUnder(event: PointerEvent) {
    const element = document.elementFromPoint(event.clientX, event.clientY);
    return element instanceof HTMLElement ? element.closest<HTMLElement>("[data-letter]")?.dataset.letter : undefined;
  }

  return (
    <nav
      aria-label="Jump to letter"
      className="fixed bottom-0 right-0 top-14 z-10 flex touch-none select-none flex-col justify-center py-2 pr-0.5 sm:pr-1 lg:top-0"
      onPointerDown={(event) => {
        if (event.pointerType === "mouse") return;
        event.currentTarget.setPointerCapture(event.pointerId);
        last.current = null;
        jump(letterUnder(event));
      }}
      onPointerMove={(event) => {
        if (event.currentTarget.hasPointerCapture(event.pointerId)) jump(letterUnder(event));
      }}
    >
      {ALPHABET.map((letter) => {
        const present = at.has(letter);
        return (
          <button
            key={letter}
            type="button"
            data-letter={letter}
            disabled={!present}
            aria-label={letter === "#" ? "Jump to numbers and symbols" : `Jump to ${letter}`}
            onClick={() => {
              last.current = null;
              jump(letter);
            }}
            className={cn(
              "flex min-h-0 w-6 max-h-6 flex-1 items-center justify-center rounded-[var(--radius-control)] text-[10px] font-semibold leading-none sm:w-7 sm:text-xs",
              present ? "text-muted hover:bg-surface-raised hover:text-primary" : "text-muted/30",
            )}
          >
            {letter}
          </button>
        );
      })}
    </nav>
  );
}
