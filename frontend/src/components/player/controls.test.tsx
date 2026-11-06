import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { LiveBadge, ScrubBar, VolumeControl } from "@/components/player/controls";

const bar = (onStep: (seconds: number) => void, onFraction: (fraction: number) => void = vi.fn()) => (
  <ScrubBar label="Position" max={100} now={40} text="0:40 of 1:40" onFraction={onFraction} onStep={onStep}>
    <span />
  </ScrubBar>
);

describe("ScrubBar", () => {
  it("is a slider that says where it is", () => {
    render(bar(vi.fn()));
    const slider = screen.getByRole("slider", { name: "Position" });
    expect(slider).toHaveAttribute("aria-valuenow", "40");
    expect(slider).toHaveAttribute("aria-valuetext", "0:40 of 1:40");
  });

  it("moves with the arrow keys, which stop there", () => {
    const onStep = vi.fn();
    const page = vi.fn();
    document.addEventListener("keydown", page);
    render(bar(onStep));
    const slider = screen.getByRole("slider");
    fireEvent.keyDown(slider, { key: "ArrowLeft" });
    fireEvent.keyDown(slider, { key: "ArrowRight" });
    expect(onStep.mock.calls).toEqual([[-10], [10]]);
    expect(page).not.toHaveBeenCalled();
    document.removeEventListener("keydown", page);
  });

  it("leaves other keys and held modifiers to the page", () => {
    const onStep = vi.fn();
    const page = vi.fn();
    document.addEventListener("keydown", page);
    render(bar(onStep));
    const slider = screen.getByRole("slider");
    fireEvent.keyDown(slider, { key: "k" });
    fireEvent.keyDown(slider, { key: "ArrowUp" });
    fireEvent.keyDown(slider, { key: "ArrowLeft", metaKey: true });
    expect(onStep).not.toHaveBeenCalled();
    expect(page).toHaveBeenCalledTimes(3);
    document.removeEventListener("keydown", page);
  });

  it("goes where it's pressed", () => {
    const onFraction = vi.fn();
    render(bar(vi.fn(), onFraction));
    const slider = screen.getByRole("slider");
    slider.getBoundingClientRect = () => ({ left: 100, width: 200 }) as DOMRect;
    fireEvent.click(slider, { clientX: 150 });
    expect(onFraction).toHaveBeenCalledWith(0.25);
  });
});

describe("LiveBadge", () => {
  it("says live at live, and offers to catch up behind it", () => {
    const onJump = vi.fn();
    const { rerender } = render(<LiveBadge atLive behind={0} onJump={onJump} testId="badge" />);
    expect(screen.getByTestId("badge")).toHaveTextContent("Live");
    rerender(<LiveBadge atLive={false} behind={65} onJump={onJump} />);
    fireEvent.click(screen.getByRole("button", { name: /Jump to live · −1:05/ }));
    expect(onJump).toHaveBeenCalledOnce();
  });
});

describe("VolumeControl", () => {
  it("shows silence on the slider while quiet, whatever the volume", () => {
    render(<VolumeControl quiet volume={0.5} onToggleMute={vi.fn()} onVolume={vi.fn()} />);
    expect(screen.getByRole("slider", { name: "Volume" })).toHaveValue("0");
    expect(screen.getByRole("button", { name: "Unmute (m)" })).toBeInTheDocument();
  });
});
