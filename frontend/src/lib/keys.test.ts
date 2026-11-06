import { describe, expect, it } from "vitest";
import { isTypingTarget, notAShortcut } from "@/lib/keys";

describe("isTypingTarget", () => {
  it("is every field a person types or picks in", () => {
    for (const tag of ["input", "textarea", "select"]) expect(isTypingTarget(document.createElement(tag))).toBe(true);
  });

  it("isn't the page, a button, or nothing", () => {
    expect(isTypingTarget(document.body)).toBe(false);
    expect(isTypingTarget(document.createElement("button"))).toBe(false);
    expect(isTypingTarget(null)).toBe(false);
  });
});

describe("notAShortcut", () => {
  const key = (init: KeyboardEventInit, target: HTMLElement = document.body) => {
    const event = new KeyboardEvent("keydown", { bubbles: true, ...init });
    target.dispatchEvent(event);
    return event;
  };

  it("leaves a held modifier to the browser", () => {
    expect(notAShortcut(key({ key: "k", metaKey: true }))).toBe(true);
    expect(notAShortcut(key({ key: "k", ctrlKey: true }))).toBe(true);
    expect(notAShortcut(key({ key: "k", altKey: true }))).toBe(true);
  });

  it("takes a plain key on the page", () => {
    const body = document.body;
    const event = new KeyboardEvent("keydown", { key: "k", bubbles: true });
    let seen = true;
    body.addEventListener("keydown", (fired) => (seen = notAShortcut(fired)), { once: true });
    body.dispatchEvent(event);
    expect(seen).toBe(false);
  });
});
