import { act, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { AtPlayhead, AtProgress, usePlayhead, type Playhead } from "@/components/player/playhead";

describe("AtProgress", () => {
  it("re-renders only the bar, and only when a thousandth goes by", () => {
    let outer = 0;
    let bar = 0;
    let handle: Playhead | null = null;
    function Frame() {
      outer += 1;
      const playhead = usePlayhead(0);
      handle = playhead;
      return (
        <AtProgress playhead={playhead} duration={1_000}>
          {(progress) => {
            bar += 1;
            return <p data-testid="bar">{progress}</p>;
          }}
        </AtProgress>
      );
    }
    render(<Frame />);
    const playhead = handle as unknown as Playhead;
    const [outerAtStart, barAtStart] = [outer, bar];

    act(() => playhead.set(0.2));
    act(() => playhead.set(0.4));
    expect(bar).toBe(barAtStart);

    act(() => playhead.set(500));
    expect(screen.getByTestId("bar")).toHaveTextContent("0.5");
    expect(bar).toBe(barAtStart + 1);
    expect(outer).toBe(outerAtStart);
  });

  it("is 0 before the duration is known", () => {
    function Frame() {
      const playhead = usePlayhead(30);
      return <AtProgress playhead={playhead} duration={0}>{(progress) => <p data-testid="bar">{progress}</p>}</AtProgress>;
    }
    render(<Frame />);
    expect(screen.getByTestId("bar")).toHaveTextContent("0");
  });
});

describe("a second store for what's loaded", () => {
  it("re-renders the seek bar's slot for either, not its owner", () => {
    let outer = 0;
    let stores: { playhead: Playhead; buffered: Playhead } | null = null;
    function Frame() {
      outer += 1;
      const playhead = usePlayhead(0);
      const buffered = usePlayhead(0);
      stores = { playhead, buffered };
      return (
        <AtPlayhead playhead={playhead}>
          {(current) => <AtPlayhead playhead={buffered}>{(loaded) => <p data-testid="seek">{`${current}/${loaded}`}</p>}</AtPlayhead>}
        </AtPlayhead>
      );
    }
    render(<Frame />);
    const { playhead, buffered } = stores as unknown as { playhead: Playhead; buffered: Playhead };
    const start = outer;
    act(() => buffered.set(42));
    act(() => playhead.set(7));
    expect(screen.getByTestId("seek")).toHaveTextContent("7/42");
    expect(outer).toBe(start);
  });
});
