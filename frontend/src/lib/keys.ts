/** Someone typing here: their keys are theirs, not a shortcut's. */
export function isTypingTarget(target: EventTarget | null): boolean {
  return (
    target instanceof HTMLInputElement ||
    target instanceof HTMLTextAreaElement ||
    target instanceof HTMLSelectElement ||
    (target instanceof HTMLElement && target.isContentEditable === true)
  );
}

/** A browser or system shortcut, held down. */
export function heldModifier(event: KeyboardEvent): boolean {
  return event.metaKey || event.ctrlKey || event.altKey;
}

/** A key a page's own single-key shortcuts leave alone. */
export function notAShortcut(event: KeyboardEvent): boolean {
  return isTypingTarget(event.target) || heldModifier(event);
}
