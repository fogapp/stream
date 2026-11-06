import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ConfirmButton } from "./ConfirmButton";

describe("ConfirmButton", () => {
  it("asks before it acts", () => {
    const onConfirm = vi.fn();
    render(
      <ConfirmButton onConfirm={onConfirm} question="Delete it?">
        Delete
      </ConfirmButton>,
    );
    fireEvent.click(screen.getByRole("button", { name: "Delete" }));
    expect(onConfirm).not.toHaveBeenCalled();
    expect(screen.getByText("Delete it?")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Yes" }));
    expect(onConfirm).toHaveBeenCalledTimes(1);
  });

  it("backs out on No", () => {
    const onConfirm = vi.fn();
    render(<ConfirmButton onConfirm={onConfirm}>Remove</ConfirmButton>);
    fireEvent.click(screen.getByRole("button", { name: "Remove" }));
    fireEvent.click(screen.getByRole("button", { name: "No" }));
    expect(onConfirm).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: "Remove" })).toBeInTheDocument();
  });
});
