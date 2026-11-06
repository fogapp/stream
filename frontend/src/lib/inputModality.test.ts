import { afterEach, describe, expect, it } from "vitest";
import { trackInputModality } from "./inputModality";

describe("trackInputModality", () => {
  let stop: () => void = () => undefined;
  afterEach(() => {
    stop();
    delete document.documentElement.dataset.input;
  });

  it("is pointer after a press and keyboard only after Tab", () => {
    stop = trackInputModality();
    const root = document.documentElement;
    expect(root.dataset.input).toBeUndefined();

    document.body.dispatchEvent(new Event("pointerdown", { bubbles: true }));
    expect(root.dataset.input).toBe("pointer");

    document.body.dispatchEvent(new KeyboardEvent("keydown", { key: " ", bubbles: true }));
    expect(root.dataset.input).toBe("pointer");

    document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "Tab", bubbles: true }));
    expect(root.dataset.input).toBe("keyboard");
  });
});
