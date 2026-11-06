/**
 * Whether the person is steering by pointer or by keyboard, on
 * `<html data-input>`, so the focus ring follows the keyboard alone.
 *
 * `:focus-visible` on its own isn't enough: a browser shows the ring on a
 * clicked button as soon as any key is pressed (Space to pause after
 * clicking a player control), and on focus moved by script after a click.
 * Only Tab hands the ring back — the other keys are the player's and the
 * page's shortcuts, not a move between controls.
 */
export function trackInputModality(root: HTMLElement = document.documentElement): () => void {
  const pointer = () => {
    root.dataset.input = "pointer";
  };
  const key = (event: KeyboardEvent) => {
    if (event.key === "Tab") root.dataset.input = "keyboard";
  };
  document.addEventListener("pointerdown", pointer, true);
  document.addEventListener("keydown", key, true);
  return () => {
    document.removeEventListener("pointerdown", pointer, true);
    document.removeEventListener("keydown", key, true);
  };
}
