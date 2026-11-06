import { describe, expect, it, vi } from "vitest";
import { runPlayerKey, stepSpeed, type PlayerKeyActions } from "@/components/player/playerKeymap";

function actions(overrides: Partial<PlayerKeyActions> = {}): PlayerKeyActions {
  return {
    element: { paused: true, duration: 100 } as HTMLVideoElement,
    position: () => 50,
    seekTo: vi.fn(),
    togglePlay: vi.fn(),
    volume: 0.5,
    changeVolume: vi.fn(),
    mute: vi.fn(),
    changeRate: vi.fn(),
    frameRate: 25,
    toggleSubtitles: vi.fn(),
    info: vi.fn(),
    toggleSize: vi.fn(),
    next: vi.fn(),
    toggleKeys: vi.fn(),
    toggleFullscreen: vi.fn(),
    toggleStats: vi.fn(),
    toggleRelated: vi.fn(),
    escape: vi.fn(() => true),
    ...overrides,
  };
}

describe("stepSpeed", () => {
  it("moves along the list and stays on its ends", () => {
    expect(stepSpeed(1, 1)).toBe(1.25);
    expect(stepSpeed(1, -1)).toBe(0.75);
    expect(stepSpeed(2, 1)).toBe(2);
    expect(stepSpeed(0.5, -1)).toBe(0.5);
  });
});

describe("runPlayerKey", () => {
  it("seeks ten on j and l, five on the arrows, from where the viewer is", () => {
    const player = actions();
    runPlayerKey("j", player);
    runPlayerKey("l", player);
    runPlayerKey("ArrowLeft", player);
    runPlayerKey("ArrowRight", player);
    expect(vi.mocked(player.seekTo).mock.calls).toEqual([[40], [60], [45], [55]]);
  });

  it("steps a frame only while paused, at the file's rate", () => {
    const paused = actions();
    expect(runPlayerKey(".", paused)).toBe(true);
    expect(paused.seekTo).toHaveBeenCalledWith(50.04);

    const playing = actions({ element: { paused: false, duration: 100 } as HTMLVideoElement });
    expect(runPlayerKey(".", playing)).toBe(false);
    expect(playing.seekTo).not.toHaveBeenCalled();
  });

  it("takes a number as a tenth of the way through", () => {
    const player = actions();
    expect(runPlayerKey("3", player)).toBe(true);
    expect(player.seekTo).toHaveBeenCalledWith(30);
  });

  it("leaves the page what isn't the player's", () => {
    expect(runPlayerKey("q", actions())).toBe(false);
    expect(runPlayerKey("i", actions({ info: null }))).toBe(false);
    expect(runPlayerKey("t", actions({ toggleSize: null }))).toBe(false);
    expect(runPlayerKey("Escape", actions({ escape: () => false }))).toBe(false);
  });

  it("keeps N for itself with nothing next", () => {
    expect(runPlayerKey("N", actions({ next: null }))).toBe(true);
  });
});
