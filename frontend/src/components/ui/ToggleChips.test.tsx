import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { ToggleChips } from "./ToggleChips";

const OPTIONS = [
  { value: "failed", label: "Failed" },
  { value: "errored", label: "Errored" },
  { value: "stalled", label: "Stalled" },
] as const;

describe("ToggleChips", () => {
  it("turns a chip on and off, keeping the options' order", () => {
    const onChange = vi.fn();
    render(<ToggleChips label="Outcome" options={OPTIONS} selected={["stalled"]} onChange={onChange} />);

    expect(screen.getByRole("button", { name: "Stalled" })).toHaveAttribute("aria-pressed", "true");
    fireEvent.click(screen.getByRole("button", { name: "Failed" }));
    expect(onChange).toHaveBeenLastCalledWith(["failed", "stalled"]);
    fireEvent.click(screen.getByRole("button", { name: "Stalled" }));
    expect(onChange).toHaveBeenLastCalledWith([]);
  });
});
