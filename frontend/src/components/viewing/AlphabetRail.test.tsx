import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { AlphabetRail } from "./AlphabetRail";

const STARTS = [
  { letter: "#", index: 0 },
  { letter: "A", index: 2 },
  { letter: "H", index: 40 },
];

describe("AlphabetRail", () => {
  it("jumps to where a letter starts, and dims letters nothing files under", () => {
    const onJump = vi.fn();
    render(<AlphabetRail starts={STARTS} onJump={onJump} />);

    expect(screen.getAllByRole("button")).toHaveLength(27);
    expect(screen.getByRole("button", { name: "Jump to B" })).toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: "Jump to H" }));
    expect(onJump).toHaveBeenCalledWith(40);
    fireEvent.click(screen.getByRole("button", { name: "Jump to H" }));
    expect(onJump).toHaveBeenCalledTimes(2);
    fireEvent.click(screen.getByRole("button", { name: "Jump to numbers and symbols" }));
    expect(onJump).toHaveBeenLastCalledWith(0);
  });
});
