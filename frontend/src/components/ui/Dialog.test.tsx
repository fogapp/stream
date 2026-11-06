import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { Dialog } from "@/components/ui/Dialog";

describe("Dialog", () => {
  it("is named, focuses its first control, and closes on Escape and the backdrop", () => {
    const onClose = vi.fn();
    render(
      <Dialog label="Seinfeld" onClose={onClose}>
        <button type="button">Watch</button>
      </Dialog>,
    );
    expect(screen.getByRole("dialog", { name: "Seinfeld" })).toBeTruthy();
    expect(document.activeElement).toBe(screen.getByRole("button", { name: "Watch" }));
    fireEvent.keyDown(document, { key: "Escape" });
    expect(onClose).toHaveBeenCalledTimes(1);
    fireEvent.mouseDown(screen.getByRole("dialog").parentElement!);
    expect(onClose).toHaveBeenCalledTimes(2);
  });
});
