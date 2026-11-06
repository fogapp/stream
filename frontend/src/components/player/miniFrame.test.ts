import { describe, expect, it } from "vitest";
import { boxFrame, frameBox, MINI_FRAME_DEFAULT, resizeBox } from "@/components/player/miniFrame";

const screen = { width: 1280, height: 800 };

describe("the mini-player's frame", () => {
  it("starts in the bottom-right corner", () => {
    expect(frameBox(MINI_FRAME_DEFAULT, screen)).toEqual({ left: 944, top: 604, width: 320, height: 180 });
  });

  it("stays docked in its corner when the window grows", () => {
    const box = frameBox(MINI_FRAME_DEFAULT, { width: 1920, height: 1080 });
    expect(box.left + box.width).toBe(1920 - 16);
    expect(box.top + box.height).toBe(1080 - 16);
  });

  it("can't be dragged off the screen", () => {
    const frame = boxFrame(-500, 5000, 320, screen);
    expect(frameBox(frame, screen)).toMatchObject({ left: 16, top: 604 });
  });

  it("resizes from the top-left with the bottom-right corner fixed, keeping 16:9", () => {
    const start = frameBox(MINI_FRAME_DEFAULT, screen);
    const box = frameBox(resizeBox(start, "top-left", -160, 0, screen), screen);
    expect(box.width).toBe(480);
    expect(box.height).toBe(270);
    expect(box.left + box.width).toBe(start.left + start.width);
    expect(box.top + box.height).toBe(start.top + start.height);
  });

  it("never grows past the screen or shrinks past its minimum", () => {
    const start = frameBox(MINI_FRAME_DEFAULT, screen);
    expect(frameBox(resizeBox(start, "top-left", -5000, 0, screen), screen).width).toBe(1280 - 32);
    expect(frameBox(resizeBox(start, "top-left", 5000, 0, screen), screen).width).toBe(200);
  });
});

describe("resizing from a corner", () => {
  it("follows whichever way the pointer went further", () => {
    const start = frameBox(MINI_FRAME_DEFAULT, screen);
    expect(frameBox(resizeBox(start, "bottom-right", -10, 90, screen), screen).height).toBe(270);
    expect(frameBox(resizeBox(start, "bottom-left", 60, 0, screen), screen).width).toBe(260);
  });
});
