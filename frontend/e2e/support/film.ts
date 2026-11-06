import type { Locator } from "@playwright/test";

/**
 * The seed's Long Take says in a strip across the top of its picture what
 * second of the film each frame is (lib/tasks/e2e.rake): the left half's
 * grey counts seconds in fifties, the right half's counts the fifties. Reading it back tells the
 * frame on screen from the time the player says it is — a picture that has
 * frozen, or come from another part of the film, shows as the two apart.
 */
export interface Reading {
  /** The player's clock. */
  time: number;
  /** The second of the film the frame on screen says it is; null with no frame to read. */
  picture: number | null;
  seeking: boolean;
  paused: boolean;
}

export function read(video: Locator): Promise<Reading> {
  return video.evaluate((element: HTMLVideoElement) => {
    let picture: number | null = null;
    if (element.readyState >= 2 && element.videoWidth > 0) {
      const canvas = document.createElement("canvas");
      canvas.width = 64;
      canvas.height = 36;
      const context = canvas.getContext("2d")!;
      context.drawImage(element, 0, 0, 64, 36);
      // The canvas is full range; the film's greys are video range.
      const luma = (x: number) => {
        const pixels = context.getImageData(x, 2, 12, 8).data;
        let sum = 0;
        for (let i = 0; i < pixels.length; i += 4) sum += pixels[i + 1]!;
        return (sum / (pixels.length / 4)) * (219 / 255);
      };
      picture = Math.round(luma(10) / 4) + 50 * Math.round(luma(42) / 40);
    }
    return { time: element.currentTime, picture, seeking: element.seeking, paused: element.paused };
  });
}
