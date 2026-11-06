import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { Segmented } from "./Segmented";

const SEGMENTS = [
  { key: "auto", label: "Auto" },
  { key: "only", label: "Only" },
  { key: "never", label: "Never" },
] as const;

describe("Segmented", () => {
  it("marks the current value and switches on click", () => {
    const onChange = vi.fn();
    render(<Segmented segments={SEGMENTS} value="auto" onChange={onChange} label="Scope" />);

    expect(screen.getByRole("radio", { name: "Auto" })).toHaveAttribute("aria-checked", "true");
    fireEvent.click(screen.getByRole("radio", { name: "Never" }));
    expect(onChange).toHaveBeenCalledWith("never");
  });

  it("moves with arrow keys and wraps at the ends", () => {
    const onChange = vi.fn();
    render(<Segmented segments={SEGMENTS} value="auto" onChange={onChange} label="Scope" />);

    fireEvent.keyDown(screen.getByRole("radiogroup"), { key: "ArrowLeft" });
    expect(onChange).toHaveBeenCalledWith("never");
  });
});
