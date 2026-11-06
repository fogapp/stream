import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { Menu } from "./Menu";

function open() {
  fireEvent.click(screen.getByRole("button", { name: "Show settings" }));
}

describe("Menu", () => {
  it("keeps its panel closed until the trigger is clicked", () => {
    render(
      <Menu label="Show settings" icon={<span aria-hidden>·</span>}>
        <p>Priority</p>
      </Menu>,
    );
    expect(screen.queryByText("Priority")).not.toBeInTheDocument();
    open();
    expect(screen.getByText("Priority")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Show settings" })).toHaveAttribute("aria-expanded", "true");
  });

  it("closes on Escape and on a pointerdown outside", () => {
    render(
      <div>
        <Menu label="Show settings" icon={<span aria-hidden>·</span>}>
          <p>Priority</p>
        </Menu>
        <button type="button">Elsewhere</button>
      </div>,
    );

    open();
    fireEvent.keyDown(document, { key: "Escape" });
    expect(screen.queryByText("Priority")).not.toBeInTheDocument();

    open();
    fireEvent.pointerDown(screen.getByRole("button", { name: "Elsewhere" }));
    expect(screen.queryByText("Priority")).not.toBeInTheDocument();
  });

  it("stays open for a click on its own contents", () => {
    render(
      <Menu label="Show settings" icon={<span aria-hidden>·</span>}>
        <label htmlFor="priority">Priority</label>
        <input id="priority" />
      </Menu>,
    );
    open();
    fireEvent.pointerDown(screen.getByLabelText("Priority"));
    expect(screen.getByLabelText("Priority")).toBeInTheDocument();
  });
});
