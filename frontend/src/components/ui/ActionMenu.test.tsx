import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { ActionMenu, ActionMenuItem } from "./ActionMenu";

function renderMenu(onWatched = vi.fn()) {
  render(
    <div>
      <ActionMenu label="More for Heat">
        {(close) => (
          <>
            <ActionMenuItem onSelect={() => undefined}>Play</ActionMenuItem>
            <ActionMenuItem
              onSelect={() => {
                onWatched();
                close();
              }}
            >
              Mark as watched
            </ActionMenuItem>
          </>
        )}
      </ActionMenu>
      <button type="button">Elsewhere</button>
    </div>,
  );
  return onWatched;
}

describe("ActionMenu", () => {
  it("renders its commands only once opened, focusing the first", () => {
    renderMenu();
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "More for Heat" }));
    expect(screen.getByRole("menu", { name: "More for Heat" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Play" })).toHaveFocus();
  });

  it("moves with the arrow keys, runs a command, and gives focus back", () => {
    const onWatched = renderMenu();
    const trigger = screen.getByRole("button", { name: "More for Heat" });
    fireEvent.click(trigger);
    fireEvent.keyDown(screen.getByRole("menu"), { key: "ArrowDown" });
    expect(screen.getByRole("menuitem", { name: "Mark as watched" })).toHaveFocus();
    fireEvent.keyDown(screen.getByRole("menu"), { key: "ArrowDown" });
    expect(screen.getByRole("menuitem", { name: "Play" })).toHaveFocus();
    fireEvent.keyDown(screen.getByRole("menu"), { key: "ArrowUp" });
    fireEvent.click(screen.getByRole("menuitem", { name: "Mark as watched" }));
    expect(onWatched).toHaveBeenCalledOnce();
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();
  });

  it("closes on Escape and on a pointerdown outside", () => {
    renderMenu();
    fireEvent.click(screen.getByRole("button", { name: "More for Heat" }));
    fireEvent.keyDown(screen.getByRole("menu"), { key: "Escape" });
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "More for Heat" }));
    fireEvent.pointerDown(screen.getByRole("button", { name: "Elsewhere" }));
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });
});
