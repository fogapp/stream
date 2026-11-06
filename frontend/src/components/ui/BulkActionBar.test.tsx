import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { BulkActionBar } from "./BulkActionBar";

describe("BulkActionBar", () => {
  it("shows nothing with nothing selected", () => {
    const { container } = render(
      <BulkActionBar count={0} onClear={() => {}}>
        <button type="button">Optimize</button>
      </BulkActionBar>,
    );
    expect(container).toBeEmptyDOMElement();
  });

  it("says how many are selected and clears them", () => {
    const onClear = vi.fn();
    render(
      <BulkActionBar count={1204} noun="files selected" onClear={onClear}>
        <button type="button">Optimize</button>
      </BulkActionBar>,
    );
    expect(screen.getByRole("region", { name: "Selected rows" })).toHaveTextContent("1,204 files selected");
    fireEvent.click(screen.getByRole("button", { name: "Clear selection" }));
    expect(onClear).toHaveBeenCalled();
  });
});
