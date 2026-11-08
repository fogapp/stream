import { act, render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";
import { PlaybackProvider, usePlayback, usePlaybackActions, usePlayingTitle } from "@/hooks/usePlayback";
import type { NextItem } from "@/types";

vi.mock("@/hooks/useProfile", () => ({ useProfile: () => ({ profile: { id: "p1" } }) }));
vi.mock("@/components/player/Player", () => ({ Player: () => null }));

const item = (id: string): NextItem => ({ kind: "episode", id, code: null, title: id, show_title: null, image: null, playlist_id: null });

describe("PlaybackProvider", () => {
  it("keeps what only acts out of playback's re-renders, and its actions reach the latest state", () => {
    const seen: { actions: ReturnType<typeof usePlaybackActions>[]; acting: number; title: number } = { actions: [], acting: 0, title: 0 };
    function Acting() {
      seen.actions.push(usePlaybackActions());
      seen.acting += 1;
      return null;
    }
    function Title() {
      usePlayingTitle();
      seen.title += 1;
      return null;
    }
    function State() {
      const { queue, size } = usePlayback();
      return <p data-testid="state">{`${size}:${queue.map((queued) => queued.id).join(",")}`}</p>;
    }
    render(
      <MemoryRouter>
        <PlaybackProvider>
          <Acting />
          <Title />
          <State />
        </PlaybackProvider>
      </MemoryRouter>,
    );
    const [actions] = seen.actions;
    const acting = seen.acting;
    const title = seen.title;

    act(() => {
      actions.enqueue(item("a"));
    });
    // Called through the first render's function: the queue it had then was empty.
    act(() => {
      actions.enqueue(item("b"));
    });
    act(() => actions.setSize("wide"));

    expect(screen.getByTestId("state")).toHaveTextContent("wide:a,b");
    expect(seen.acting).toBe(acting);
    expect(seen.title).toBe(title);
    expect(new Set(seen.actions).size).toBe(1);
  });
});
