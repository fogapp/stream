import { afterEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { LivePlayer } from "@/components/live/LivePlayer";
import { rememberMuted, rememberVolume } from "@/lib/volume";
import type { PlaybackSessionInfo } from "@/types";

vi.mock("@/hooks/usePlayback", () => ({ usePlayback: () => ({ mainSilenced: false, hearMain: vi.fn(), pip: null }) }));
vi.mock("@/components/live/ChannelBar", () => ({ ChannelBar: () => null }));
vi.mock("@/components/pip/PipPicker", () => ({ PipPicker: () => null }));

const session = (id: string, subtitles: unknown[] = []) =>
  ({ id, title: id, subtitles, fonts: [], source: { kind: "file" }, events_url: "/events", progress_url: "/progress", duration_seconds: 60 }) as unknown as PlaybackSessionInfo;

/** The page keys the controls by session, so each program mounts them anew, on its own element. */
function program(id: string, video: HTMLVideoElement, subtitles: unknown[] = []) {
  return (
    <LivePlayer
      key={id}
      video={video}
     
      session={session(id, subtitles)}
      airing={null}
      next={null}
      timeZone="UTC"
      skew={0}
      keys
      onEnded={vi.fn()}
      onRestart={vi.fn()}
      onBack={vi.fn()}
      onChannel={vi.fn()}
      onGuide={vi.fn()}
      onNow={vi.fn()}
      nowOpen={false}
      bannerKey={id}
    />
  );
}

describe("LivePlayer", () => {
  afterEach(() => rememberMuted(false));

  it("keeps a mute from one program to the next, until it's unmuted at the old volume", () => {
    rememberVolume(0.4);
    const first = document.createElement("video");
    const second = document.createElement("video");
    const { rerender } = render(program("first", first));
    expect(first.muted).toBe(false);

    fireEvent.click(screen.getByRole("button", { name: "Mute (m)" }));
    expect(first.muted).toBe(true);

    rerender(program("second", second));
    expect(second.muted).toBe(true);
    expect(second.volume).toBe(0);

    fireEvent.click(screen.getByRole("button", { name: "Unmute (m)" }));
    expect(second.muted).toBe(false);
    expect(second.volume).toBe(0.4);
  });

  it("unmutes to the old volume on the program it was muted on", () => {
    rememberVolume(0.4);
    const video = document.createElement("video");
    render(program("only", video));
    fireEvent.click(screen.getByRole("button", { name: "Mute (m)" }));
    fireEvent.click(screen.getByRole("button", { name: "Unmute (m)" }));
    expect(video.muted).toBe(false);
    expect(video.volume).toBe(0.4);
  });

  it("offers no subtitle menu for tracks only burning in could show", () => {
    render(program("only", document.createElement("video"), [{ id: "pgs", burn: true, language: "en", title: null, forced: false }]));
    expect(screen.queryByRole("button", { name: "Subtitles" })).not.toBeInTheDocument();
  });

  it("moves through the program with the arrow keys on its bar, once a press", () => {
    const video = document.createElement("video");
    Object.defineProperty(video, "duration", { value: 60 });
    video.currentTime = 30;
    render(program("only", video));
    const bar = screen.getByRole("slider", { name: "Position in this program" });
    fireEvent.keyDown(bar, { key: "ArrowLeft" });
    expect(bar).toHaveAttribute("aria-valuenow", "20");
  });
});
